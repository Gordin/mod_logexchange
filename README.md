# Logexchange
Implementation of the Logexchange protocol developed in my bachelors thesis [Near Real-time Visual Community Analytics for XMPP-based Networks](https://gord.in/ba.pdf).

For Information on how the protocol works and what commands are available read section "4.4 XMPP log data Exchange Protocol".
# Setting up the Logexchange Plugin
1. Have a working Prosody XMPP server.
2. Clone the [prosody-modules](https://code.google.com/p/prosody-modules/source/checkout) repository and add it to your prosody config:

    ```lua
    plugin_paths = { "/path/to/prosody-modules" }
    ```
3. Get the [logexchange](https://github.com/Gordin/mod_logexchange) (this repository) and [eventlog](https://github.com/Gordin/mod_eventlog) modules and put them in the prosody-modules directory.
4. Enable the logexchange, statistics and websockets plugins in your prosody config:

    ```lua
    modules_enabled = {
        …
        "websocket";
        "statistics";
        "logexchange";
    }
    ```
5. Restart Prosody and the Logexchange AdHoc commands should be available.
6. Make sure all users who will use the commands are registered as admins in the Prosody config.
