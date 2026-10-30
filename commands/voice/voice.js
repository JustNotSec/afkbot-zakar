const {
    SlashCommandBuilder,
    ChannelType,
    PermissionFlagsBits,
    MessageFlags,
} = require('discord.js');
const voiceManager = require('../../lib/voiceManager');

const VOICE_TYPES = [ChannelType.GuildVoice, ChannelType.GuildStageVoice];

module.exports = {
    data: new SlashCommandBuilder()
        .setName('voice')
        .setDescription('24/7 voice AFK control')
        .addSubcommand((sub) =>
            sub
                .setName('join')
                .setDescription('Join a voice channel and stay there')
                .addChannelOption((opt) =>
                    opt
                        .setName('channel')
                        .setDescription('Target channel (defaults to your current channel)')
                        .addChannelTypes(...VOICE_TYPES)
                )
        )
        .addSubcommand((sub) =>
            sub.setName('leave').setDescription('Leave voice and stop the 24/7 session')
        )
        .addSubcommand((sub) =>
            sub.setName('status').setDescription('Show active 24/7 voice sessions')
        ),

    async execute(interaction, client) {
        if (!interaction.inGuild()) {
            return interaction.reply({ content: 'Guild only.', flags: MessageFlags.Ephemeral });
        }

        const sub = interaction.options.getSubcommand();
        if (sub === 'join') return handleJoin(interaction, client);
        if (sub === 'leave') return handleLeave(interaction);
        return handleStatus(interaction, client);
    },
};

async function handleJoin(interaction, client) {
    const guild = interaction.guild;
    const target = interaction.options.getChannel('channel') ?? interaction.member.voice?.channel;

    if (!target) {
        return interaction.reply({
            content: 'Pick a channel or join one first.',
            flags: MessageFlags.Ephemeral,
        });
    }

    if (!VOICE_TYPES.includes(target.type)) {
        return interaction.reply({
            content: 'That is not a voice channel.',
            flags: MessageFlags.Ephemeral,
        });
    }

    const me = guild.members.me ?? (await guild.members.fetch(client.user.id).catch(() => null));
    const perms = target.permissionsFor(me);
    if (!perms || !perms.has(PermissionFlagsBits.ViewChannel) || !perms.has(PermissionFlagsBits.Connect)) {
        return interaction.reply({
            content: `Missing View Channel or Connect permission in ${target}.`,
            flags: MessageFlags.Ephemeral,
        });
    }

    await interaction.deferReply({ flags: MessageFlags.Ephemeral });

    try {
        await voiceManager.join(client, target);
        await interaction.editReply({
            content: `Connected to ${target}. Staying until \`/voice leave\`.`,
        });
    } catch (error) {
        await interaction.editReply({ content: `Join failed: ${error.message}` });
    }
}

async function handleLeave(interaction) {
    const session = voiceManager.getSession(interaction.guild.id);
    if (!session) {
        return interaction.reply({
            content: 'No active 24/7 session here.',
            flags: MessageFlags.Ephemeral,
        });
    }

    voiceManager.leave(interaction.guild.id);
    return interaction.reply({
        content: `Left <#${session.channelId}> and cleared the session.`,
        flags: MessageFlags.Ephemeral,
    });
}

async function handleStatus(interaction, client) {
    const sessions = voiceManager.listSessions();
    if (!sessions.length) {
        return interaction.reply({
            content: 'No active 24/7 sessions.',
            flags: MessageFlags.Ephemeral,
        });
    }

    const lines = sessions.map((session) => {
        const guild = client.guilds.cache.get(session.guildId);
        const since = Math.floor(session.joinedAt / 1000);
        return `• **${guild?.name ?? session.guildId}** → <#${session.channelId}> (since <t:${since}:R>)`;
    });

    return interaction.reply({ content: lines.join('\n'), flags: MessageFlags.Ephemeral });
}
