module Bot
  module DiscordEvents
    module GameMessage
      extend Discordrb::EventContainer

      message(with_text: %r{.}) do |event|
        game = Game.channel(event.channel)
        next unless game

        player = Player.where(discord_id: event.user.id.to_s, game: game).first || Player.create(discord_id: event.user.id.to_s, game: game)

        player.answer! event.message.content, game.current_question
      end
    end
  end
end
