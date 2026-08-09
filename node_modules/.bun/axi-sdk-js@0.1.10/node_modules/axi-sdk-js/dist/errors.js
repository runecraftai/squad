export class AxiError extends Error {
    code;
    suggestions;
    constructor(message, code, suggestions = []) {
        super(message);
        this.code = code;
        this.suggestions = suggestions;
        this.name = "AxiError";
    }
}
export function exitCodeForError(error) {
    if (error instanceof AxiError && error.code === "VALIDATION_ERROR") {
        return 2;
    }
    return 1;
}
