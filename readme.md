# 🛰️ MatrixChat for Minetest

Ever wanted your Minetest server to scream into the void of the internet? Now it can—via Matrix. **MatrixChat** is a bridge between your blocky sandbox and the real world, syncing chat messages, player events, and server status to a Matrix room. Because why suffer in silence?

---

## 💡 Features

- 🔄 Syncs in-game chat to a Matrix room (yes, even the weird stuff).
- 👋 Announces player joins and ragequits.
- 🧠 Sends server status updates like restarts and errors.
- 🧵 Receives Matrix messages and echoes them in-game.
- 🔐 Handles login, logout, and sync like a polite bot should.

---

## ⚙️ Configuration

Set these in your `minetest.conf` to get started:

| Setting           | Description                                      |
|-------------------|--------------------------------------------------|
| `MATRIX_SERVER`   | Your Matrix homeserver URL (e.g. `https://matrix.org`) |
| `MATRIX_ROOM`     | Room alias or ID (e.g. `#yourroom:matrix.org` or `!abc123:matrix.org`) |
| `MATRIX_USERNAME` | Matrix username (without the `@`)               |
| `MATRIX_PASSWORD` | Matrix account password                         |

> 🔐 Make sure `matrix_bridge` is listed in `secure.http_mods`, or the mod will throw a tantrum.

---

## 🧙 Privileges & Commands

| Privilege | Description                        |
|----------|------------------------------------|
| `matrix` | Allows managing the Matrix session |

| Command          | Description                                |
|------------------|--------------------------------------------|
| `/matrix login`  | Logs in to Matrix                          |
| `/matrix logout` | Logs out of Matrix                         |
| `/matrix sync`   | Manually triggers a sync                   |
| `/matrix print`  | Prints the sync URL to the server console  |
| `/restart <msg>` | Sends a restart message and shuts down the server |

---

## 🔄 Automatic Sync

The mod syncs every 60 seconds, assuming:

- Someone’s online
- The bot is logged in
- The Matrix gods are smiling upon you

---

## 🧼 Clean Code?

Let’s just say it works. Mostly. If something breaks, the mod will log the error, send a dramatic farewell to Matrix.

---

## 🐛 Bugs?

If you find one, congratulations—you’ve unlocked a new feature. Feel free to fix it, report it, or ignore it and hope it goes away.

---

## ❤️ Credits

Made with love, Lua, and a healthy dose of existential dread.

---

## 🚀 Final Thoughts

MatrixChat is the mod that makes your server feel alive—by yelling into the internet every time someone joins, leaves, or types “hi.” It’s like social media, but for cubes.

Now go forth and let your server scream.
