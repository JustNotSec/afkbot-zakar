const fs = require('node:fs');
const path = require('node:path');
const {
    joinVoiceChannel,
    getVoiceConnection,
    VoiceConnectionStatus,
    entersState,
} = require('@discordjs/voice');

const DATA_DIR = path.join(__dirname, '..', 'data');
const SESSION_FILE = path.join(DATA_DIR, 'voice-sessions.json');

const sessions = new Map();
const pending = new Map();
const leaving = new Set();

function loadSessions() {
    sessions.clear();
    let raw;
    try {
        raw = fs.readFileSync(SESSION_FILE, 'utf8');
    } catch {
        return;
    }

    let parsed;
    try {
        parsed = JSON.parse(raw);
    } catch (error) {
        console.error(`[VOICE] Corrupt session file, ignoring: ${error.message}`);
        return;
    }

    if (!parsed || typeof parsed !== 'object') return;

    for (const [guildId, value] of Object.entries(parsed)) {
        if (!value || typeof value.channelId !== 'string') continue;
        sessions.set(guildId, {
            channelId: value.channelId,
            joinedAt: Number.isFinite(value.joinedAt) ? value.joinedAt : Date.now(),
        });
    }
}

function saveSessions() {
    const payload = {};
    for (const [guildId, value] of sessions) {
        payload[guildId] = value;
    }

    try {
        fs.mkdirSync(DATA_DIR, { recursive: true });
        const tmp = `${SESSION_FILE}.tmp`;
        fs.writeFileSync(tmp, JSON.stringify(payload, null, 2));
        fs.renameSync(tmp, SESSION_FILE);
    } catch (error) {
        console.error(`[VOICE] Failed to persist sessions: ${error.message}`);
    }
}

function getSession(guildId) {
    return sessions.get(guildId) ?? null;
}

function listSessions() {
    return [...sessions.entries()].map(([guildId, value]) => ({ guildId, ...value }));
}

function cancelRejoin(guildId) {
    const timer = pending.get(guildId);
    if (!timer) return;
    clearTimeout(timer);
    pending.delete(guildId);
}

function wire(client, guildId, connection) {
    connection.on('error', (error) => {
        console.error(`[VOICE] ${guildId} connection error: ${error.message}`);
    });

    connection.on(VoiceConnectionStatus.Disconnected, async () => {
        try {
            await Promise.race([
                entersState(connection, VoiceConnectionStatus.Signalling, 5_000),
                entersState(connection, VoiceConnectionStatus.Connecting, 5_000),
            ]);
        } catch {
            connection.destroy();
            scheduleRejoin(client, guildId, 0);
        }
    });

    connection.on(VoiceConnectionStatus.Destroyed, () => {
        if (leaving.has(guildId)) return;
        scheduleRejoin(client, guildId, 0);
    });
}

async function resolveChannel(client, guildId, channelId) {
    const guild = client.guilds.cache.get(guildId) ?? (await client.guilds.fetch(guildId).catch(() => null));
    if (!guild) return null;
    return guild.channels.cache.get(channelId) ?? (await guild.channels.fetch(channelId).catch(() => null));
}

async function join(client, channel) {
    const guildId = channel.guild.id;
    cancelRejoin(guildId);
    leaving.delete(guildId);

    const existing = getVoiceConnection(guildId);
    if (existing && existing.joinConfig.channelId === channel.id) {
        await entersState(existing, VoiceConnectionStatus.Ready, 30_000);
        sessions.set(guildId, { channelId: channel.id, joinedAt: Date.now() });
        saveSessions();
        return existing;
    }
    if (existing) {
        leaving.add(guildId);
        existing.destroy();
        leaving.delete(guildId);
    }

    const connection = joinVoiceChannel({
        channelId: channel.id,
        guildId,
        adapterCreator: channel.guild.voiceAdapterCreator,
        selfDeaf: true,
        selfMute: true,
    });

    wire(client, guildId, connection);
    await entersState(connection, VoiceConnectionStatus.Ready, 30_000);

    sessions.set(guildId, { channelId: channel.id, joinedAt: Date.now() });
    saveSessions();
    return connection;
}

function leave(guildId) {
    cancelRejoin(guildId);
    sessions.delete(guildId);
    saveSessions();

    leaving.add(guildId);
    const connection = getVoiceConnection(guildId);
    if (connection) connection.destroy();
    leaving.delete(guildId);
}

function scheduleRejoin(client, guildId, attempt = 0) {
    if (pending.has(guildId)) return;
    if (!sessions.has(guildId)) return;
    if (leaving.has(guildId)) return;

    const delay = Math.min(5_000 * 2 ** attempt, 60_000);
    console.log(`[VOICE] Rejoin ${guildId} in ${delay}ms (attempt ${attempt + 1})`);

    const timer = setTimeout(async () => {
        pending.delete(guildId);

        const session = sessions.get(guildId);
        if (!session) return;

        try {
            const channel = await resolveChannel(client, guildId, session.channelId);
            if (!channel) {
                console.error(`[VOICE] Channel ${session.channelId} gone in ${guildId}, dropping session`);
                sessions.delete(guildId);
                saveSessions();
                return;
            }
            await join(client, channel);
            console.log(`[VOICE] Rejoined ${guildId} -> ${session.channelId}`);
        } catch (error) {
            console.error(`[VOICE] Rejoin failed for ${guildId}: ${error.message}`);
            scheduleRejoin(client, guildId, attempt + 1);
        }
    }, delay);

    pending.set(guildId, timer);
}

async function restoreAll(client) {
    for (const { guildId, channelId } of listSessions()) {
        try {
            const channel = await resolveChannel(client, guildId, channelId);
            if (!channel) {
                console.error(`[VOICE] Cannot restore ${guildId}: channel ${channelId} missing`);
                sessions.delete(guildId);
                saveSessions();
                continue;
            }
            await join(client, channel);
            console.log(`[VOICE] Restored ${guildId} -> ${channelId}`);
        } catch (error) {
            console.error(`[VOICE] Restore failed for ${guildId}: ${error.message}`);
            scheduleRejoin(client, guildId, 1);
        }
    }
}

function handleVoiceState(client, newState) {
    if (!client.user || newState.id !== client.user.id) return;

    const guildId = newState.guild.id;
    const session = sessions.get(guildId);
    if (!session) return;

    if (newState.channelId === null) {
        scheduleRejoin(client, guildId, 0);
        return;
    }

    if (newState.channelId !== session.channelId) {
        sessions.set(guildId, {
            channelId: newState.channelId,
            joinedAt: session.joinedAt ?? Date.now(),
        });
        saveSessions();
    }
}

loadSessions();

module.exports = {
    join,
    leave,
    getSession,
    listSessions,
    restoreAll,
    handleVoiceState,
    scheduleRejoin,
    loadSessions,
    saveSessions,
};
