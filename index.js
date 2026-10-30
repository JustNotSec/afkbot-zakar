const { Client, GatewayIntentBits, Collection } = require('discord.js');
const fs = require('fs');
require('dotenv').config();

const client = new Client({
    intents: [
        GatewayIntentBits.Guilds,
        GatewayIntentBits.GuildMessages,
        GatewayIntentBits.MessageContent,
        GatewayIntentBits.GuildMembers,
        GatewayIntentBits.GuildPresences,
        GatewayIntentBits.GuildVoiceStates
    ]
});

// Handlers
client.commands = new Collection();

["events", "commands"].forEach((handler) => {
    require(`./handlers/${handler}`)(client);
});

client.on('error', (error) => {
    console.error('[BOT] Client error:', error.message);
});

process.on('unhandledRejection', (reason) => {
    console.error('[BOT] Unhandled rejection:', reason);
});

// Optional HTTP health endpoint for hosts that require an open port.
if (process.env.PORT) {
    const http = require('node:http');
    const voiceManager = require('./lib/voiceManager');

    const server = http.createServer((req, res) => {
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({
            ok: true,
            uptime: Math.floor(process.uptime()),
            ping: client.ws.ping,
            guilds: client.guilds.cache.size,
            voice: voiceManager.listSessions().length
        }));
    });

    server.listen(Number(process.env.PORT), () => {
        console.log(`[BOT] Health endpoint on :${process.env.PORT}`);
    });
}

client.login(process.env.BOT_TOKEN);
