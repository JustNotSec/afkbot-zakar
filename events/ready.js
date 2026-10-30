const voiceManager = require('../lib/voiceManager');

module.exports = {
    name: 'ready',
    once: true,
    async execute(client) {
        console.log(`[BOT] Logged in as ${client.user.tag}`);
        await voiceManager.restoreAll(client);
    },
};
