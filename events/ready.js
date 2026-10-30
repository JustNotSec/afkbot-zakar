const { ActivityType } = require('discord.js');
const voiceManager = require('../lib/voiceManager');

const STATUS_TEXT = 'Mantengin anak anak zakar';
const STATUS_PRESENCE = 'online';

function applyPresence(client) {
    if (!client.user) return;
    client.user.setPresence({
        status: STATUS_PRESENCE,
        activities: [{ name: STATUS_TEXT, type: ActivityType.Custom }],
    });
}

module.exports = {
    name: 'ready',
    once: true,
    async execute(client) {
        console.log(`[BOT] Logged in as ${client.user.tag}`);
        applyPresence(client);
        await voiceManager.restoreAll(client);
    },
};
