require 'nobrainer'
require 'rufus-scheduler'
require 'htmlentities'

NoBrainer.configure do |config|
  config.app_name = %{certainly}
end

module Bot
  DECODER = HTMLEntities.new

  SCHEDULER = Rufus::Scheduler.new

  # How many questions to populate the game with
  # at a time, after we've just started the game
  # or we ran out.
  QUESTION_BUFFER = 10

  # How long to wait in between questions
  QUESTION_DELAY = 10

  class Game
    include NoBrainer::Document

    field :owner_id,   type: String,  required: true
    field :server_id,  type: String,  required: true
    field :channel_id, type: String,  uniq: true, required: true
    field :difficulty, type: String
    field :category,   type: Integer
    field :token,      type: String,  uniq: true
    field :active,     type: Boolean, default: false
    field :time_limit, type: Integer, default: 60

    has_many :players
    has_many :questions

    def session
      @session ||= OpenTDB::Session.new(token)
    end

    before_create do
      self.token = session.token
    end

    before_destroy do
      session.reset
      channel.delete
    end

    def server
      BOT.server server_id
    end

    def channel
      BOT.channel channel_id
    end

    def self.channel(id, act = true)
      id = id.id.to_s if id.is_a? Discordrb::Channel
      where(channel_id: id, active: act).first
    end

    def owner
      BOT.member server_id, owner_id
    end

    def current_question
      questions.to_a.find { |q| !q.expired? }
    end

    def populate(number)
      raw_questions = session.questions(number, difficulty: difficulty, category: category)

      raw_questions.map do |q|
        question = Question.create(
          text:       q[:question],
          difficulty: q[:difficulty],
          type:       q[:type],
          category:   q[:category],
          game:       self
        )

        identifiers = (%{a}..%{z}).take(1 + q[:incorrect_answers].count).shuffle

        case q[:type]
        when %q{boolean}
          Answer.create(
            text:       q[:correct_answer],
            correct:    true,
            identifier: q[:correct_answer] == %{True} ? %{a} : %{b},
            question:   question
          )

          Answer.create(
            text:       q[:incorrect_answers].first,
            correct:    true,
            identifier: q[:incorrect_answers].first == %{True} ? %{a} : %{b},
            question:   question
          )

        when %q{multiple}
          Answer.create(
            text:       q[:correct_answer],
            correct:    true,
            identifier: identifiers.shift,
            question:   question
          )

          q[:incorrect_answers].each do |e|
            Answer.create(
              text:       e,
              correct:    false,
              identifier: identifiers.shift,
              question:   question
            )
          end
        end

        question
      end
    end

    def next_question!
      if active?
        if current_question.nil?
          puts 'out of questions - populating!'
          questions = populate(QUESTION_BUFFER)
          questions.first.post!
        else
          current_question.post!
        end
      end
    end
  end

  class Question
    include NoBrainer::Document

    field      :text,       type: String, required: true
    field      :difficulty, type: String
    field      :category,   type: String
    field      :type,       type: Enum, in: [:boolean, :multiple]
    field      :message_id, type: String
    field      :expires,    type: Time

    belongs_to :game, index: true
    has_many   :answers
    has_many   :player_answers

    before_create do
      self.text = DECODER.decode text
    end

    POINTS = {
      %{easy}   => 1,
      %{medium} => 2,
      %{hard}   => 3
    }

    def message
      game.channel.message message_id
    end

    def points
      POINTS[difficulty]
    end

    def expired?
      return false unless expires
      Time.now >= expires
    end

    def posted?
      !message_id.nil?
    end

    def [](identifier)
      answers.where(identifier: identifier).first
    end

    def identifiers
      answers.to_a.map(&:identifier)
    end

    def answered?(player)
      player_answers.to_a.map(&:player).include? player
    end

    def correct_answer
      answers.to_a.find(&:correct?)
    end

    def winners
      player_answers.to_a.select(&:correct?).map(&:player)
    end

    def to_s
      %Q{**#{text}** :thinking:}
    end

    def post!
      return if message_id

      message = game.channel.send_embed(
        to_s,
        Discordrb::Webhooks::Embed.new(
          description: answers.sort_by(&:identifier).map(&:to_s).join(%Q{\n}),
          color: 0x3b88c3,
          footer: { text: %Q{#{category}, #{difficulty} (#{points} point#{points > 1 ? %{s} : %{}})} }
        )
      )

      expiry_time = Time.now + game.time_limit

      update(
        expires:    expiry_time,
        message_id: message.id.to_s
      )

      SCHEDULER.at(expiry_time) do
        post_results!
        sleep QUESTION_DELAY
        Game.channel(message.channel)&.next_question!
      end

      self
    end

    def post_results!
      game.channel.send_embed(%Q{\u{1f4a1} **Time's up!**\nThe correct answer is: :regional_indicator_#{correct_answer.identifier}: **#{correct_answer.text}**}) do |embed|
        embed.color = 0x3b88c3

        if winners.any?
          embed.description = %Q{\u{2b50} **Winners: #{winners.to_a.map(&:member).map(&:name).join(%{, })}**}
        end

        if game.players.any?
          embed.add_field(
            name: %{Leaderboard},
            value: game.players
                       .to_a.sort_by(&:score).reverse.take(10)
                       .map.with_index { |p, i| %Q{**#{i + 1}.** #{p.member.display_name} (#{p.score} points)} }
                       .join(%Q{\n})
          )
        end
      end
    end
  end

  class Answer
    include NoBrainer::Document

    field      :text,       type: String,  required: true
    field      :correct,    type: Boolean, required: true
    field      :identifier, type: String,  required: true

    belongs_to :question

    before_create do
      self.text = DECODER.decode text
    end

    def to_s
      %Q{:regional_indicator_#{identifier}: **#{text}**}
    end
  end

  class Player
    include NoBrainer::Document

    field      :discord_id, type: String,  required: true
    field      :score,      type: Integer, default: 0

    has_many   :player_answers
    belongs_to :game, index: true

    def member
      BOT.user(discord_id).on(game.server)
    end

    def update_score!
      update(
        score: player_answers.to_a
                             .map { |a| a.correct? ? a.question.points : 0 }
                             .reduce(:+)
      )
    end

    def answer!(identifier, question = nil)
      question ||= game.current_question
      answer = question[identifier]

      if answer && !question.answered?(self)
        PlayerAnswer.create(
          player:   self,
          question: question,
          answer:   answer
        )

        return answer.correct?
      end
    end
  end

  class PlayerAnswer
    include NoBrainer::Document

    belongs_to :player
    belongs_to :question
    belongs_to :answer

    def correct?
      answer.correct?
    end

    after_create do
      player.update_score!
    end

    after_destroy do
      player.update_score!
    end
  end

  NoBrainer.sync_indexes
end
