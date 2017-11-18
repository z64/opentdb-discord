module Bot
  module DiscordCommands
    module GameCommands
      extend Discordrb::Commands::CommandContainer

      command(:new, permission_level: 1) do |event|
        existing_game = Game.where(server_id: event.server.id.to_s, active: true).first
        next %Q{`existing game:` #{existing_game.channel.mention} (owner: #{existing_game.owner.distinct})} if existing_game

        channel = event.server.create_channel %{trivia}

        Game.create(
          server_id: event.server.id.to_s,
          channel_id: channel.id.to_s,
          owner_id: event.user.id.to_s
        )

        %Q{`created game:` #{channel.mention}}
      end

      command(:end, permission_level: 1) do |event|
        existing_game = Game.where(channel_id: event.channel.id.to_s).first
        next %Q{`no existing game in this channel`} unless existing_game

        existing_game.update active: false
        existing_game.channel.delete

        nil
      end

      command(:start, permission_level: 1) do |event|
        existing_game = Game.channel(event.channel, false)
        next %Q{`no existing game in this channel (or game already started)`} unless existing_game

        existing_game.update active: true
        existing_game.next_question!

        nil
      end
    end
  end
end
