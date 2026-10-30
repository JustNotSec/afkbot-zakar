const voiceManager = require('../lib/voiceManager');

module.exports = {
    name: 'voiceStateUpdate',
    execute(oldState, newState, client) {
        voiceManager.handleVoiceState(client, newState);
    },
};
