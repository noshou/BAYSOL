// SPDX-License-Identifier: LGPL-3.0-or-later

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { Box, render, Text, useApp, useInput, useWindowSize } from "ink";

const assets : string = join(dirname(fileURLToPath(import.meta.url)), "..", "assets");
const logo   : string = readFileSync(join(assets, "logo", "logo-large.txt"), "utf-8");

// define option_names to be the strict constants below
const option_names = ["new", "load", "open", "settings", "help", "quit"] as const;

// define allowed names as only those in option_names
type OptionNames = typeof option_names[number];

function map_option(type: "reg"|"bold", name: OptionNames) {
    const file = `${name}-${type}.txt`;    
    return readFileSync(join(assets, "menu-options", file), "utf-8");
}

// const options_reg: Array<string> = [
//     readFileSync(join(assets, "menu-options", "new-reg.txt"), "utf-8"), 
//     readFileSync(join(assets, "menu-options", "load-reg.txt"), "utf-8"),
//     readFileSync(join(assets, "menu-options", "open-reg.txt"), "utf-8"),
//     readFileSync(join(assets, "menu-options", "settings-reg.txt"), "utf-8"),
//     readFileSync(join(assets, "menu-options", "help-reg.txt"), "utf-8"),
//     readFileSync(join(assets, "menu-options", "quit-reg.txt"), "utf-8") 
// ] 

// const options_bold: Array<string> = [
//     readFileSync(join(assets, "menu-options", "new-bold.txt"), "utf-8"), 
//     readFileSync(join(assets, "menu-options", "load-bold.txt"), "utf-8"),
//     readFileSync(join(assets, "menu-options", "open-bold.txt"), "utf-8"),
//     readFileSync(join(assets, "menu-options", "settings-bold.txt"), "utf-8"),
//     readFileSync(join(assets, "menu-options", "help-bold.txt"), "utf-8"),
//     readFileSync(join(assets, "menu-options", "quit-bold.txt"), "utf-8") 
// ] 

function App() {
    // hook for getting window size
    const { columns, rows } = useWindowSize();

    // escape is esc key
    const { exit } = useApp();
    useInput((_input, key) => {
        if (key.escape) {
            exit();
        }
    });

    return (
        <Box
            width={columns}
            height={rows}
            backgroundColor="#FCE5FE"
            flexDirection="column"
            justifyContent="flex-start"
            alignItems="center"
        >
            <Text color="#5B1675">{logo}</Text>
        </Box>
    );
}

// render app
render(<App></App>);
