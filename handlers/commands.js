require("dotenv").config();
const { globSync } = require("glob");
const { REST } = require("discord.js");
const { Routes } = require("discord-api-types/v10");

module.exports = async (client) => {
    const rest = new REST({ version: "10" }).setToken(process.env.BOT_TOKEN);
    const jsfiles = globSync('commands/**/*.js', { absolute: true });

    for (const fileName of jsfiles) {
        if (!fileName.endsWith(".js")) continue;
        const command = require(fileName);
        if (!command?.data?.name) {
            console.warn(`[CMD] Skipping ${fileName}: missing data.name`);
            continue;
        }
        client.commands.set(command.data.name, command);
        console.log(`[CMD] Loaded command: ${command.data.name}`);
    }

    const body = client.commands.map((command) => command.data.toJSON());

    // GUILD_ID makes registration instant; global takes up to ~1h to propagate.
    const route = process.env.GUILD_ID
        ? Routes.applicationGuildCommands(process.env.CLIENT_ID, process.env.GUILD_ID)
        : Routes.applicationCommands(process.env.CLIENT_ID);

    console.log(`[BOT] Refreshing ${body.length} application (/) commands.`);
    await rest.put(route, { body });
    console.log('[BOT] Successfully refreshed application (/) commands.');
};
