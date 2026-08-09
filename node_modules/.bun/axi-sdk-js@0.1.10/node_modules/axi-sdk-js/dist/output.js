import { homedir } from "node:os";
import { encode } from "@toon-format/toon";
export function collapseHomeDirectory(path, homeDir = homedir()) {
    if (!path.startsWith(homeDir)) {
        return path;
    }
    return `~${path.slice(homeDir.length)}`;
}
export function homeHeaderOutput(options) {
    return {
        bin: collapseHomeDirectory(options.execPath ?? process.argv[1] ?? "", options.homeDir),
        description: options.description,
    };
}
export function errorOutput(message, code, suggestions = []) {
    const output = {
        error: message,
        code,
    };
    if (suggestions.length > 0) {
        output.help = suggestions;
    }
    return output;
}
export function mergeOutput(...parts) {
    return Object.assign({}, ...parts.filter(Boolean));
}
export function renderOutput(output) {
    if (typeof output === "string") {
        return output;
    }
    return encode(output);
}
export function renderError(message, code, suggestions = []) {
    return renderOutput(errorOutput(message, code, suggestions));
}
export function renderHomeHeader(options) {
    return renderOutput(homeHeaderOutput(options));
}
