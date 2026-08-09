export type AxiStructuredOutput = Record<string, unknown>;
export type AxiRenderable = string | AxiStructuredOutput;
export declare function collapseHomeDirectory(path: string, homeDir?: string): string;
export declare function homeHeaderOutput(options: {
    description: string;
    execPath?: string;
    homeDir?: string;
}): AxiStructuredOutput;
export declare function errorOutput(message: string, code: string, suggestions?: string[]): AxiStructuredOutput;
export declare function mergeOutput(...parts: Array<AxiStructuredOutput | undefined>): AxiStructuredOutput;
export declare function renderOutput(output: AxiRenderable): string;
export declare function renderError(message: string, code: string, suggestions?: string[]): string;
export declare function renderHomeHeader(options: {
    description: string;
    execPath?: string;
    homeDir?: string;
}): string;
