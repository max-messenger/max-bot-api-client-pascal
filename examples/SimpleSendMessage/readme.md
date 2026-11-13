The simplest example of a console application to send a message through a bot.

The program does not use receiving updates from the bot API server.

During the execution, the program will ask for your bot token, chat ID (where to send the message) and the message string itself to be sent

To learn a chat ID, send any message to your bot from MAX; the chat ID is the recipient id your bot sees in updates.
Please note, the bot cannot send a message to users who have not sent the */start* command before. This is a limitation of the Max itself. However, a bot can send messages to a group if it is a member

Debug logging (`TMaxSender.LogDebug`) is disabled in this sample on purpose: with it enabled, the library log records full API request and response bodies, i.e. message texts and chat IDs (personal data).
