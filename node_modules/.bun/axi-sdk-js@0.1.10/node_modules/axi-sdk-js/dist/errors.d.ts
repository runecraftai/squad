export declare class AxiError extends Error {
    readonly code: string;
    readonly suggestions: string[];
    constructor(message: string, code: string, suggestions?: string[]);
}
export declare function exitCodeForError(error: unknown): number;
