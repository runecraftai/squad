export interface HookEntry {
    type?: string;
    command?: string;
    timeout?: number;
}
export interface HookGroup {
    matcher?: string | null;
    hooks?: HookEntry[];
}
export interface HookSettings {
    hooks?: {
        SessionStart?: HookGroup[];
        session_start?: HookEntry[];
        [event: string]: HookGroup[] | HookEntry[] | undefined;
    };
    [key: string]: unknown;
}
export interface ManagedHookSpec {
    marker: string;
    command: string;
    timeoutSeconds?: number;
}
export interface NodeAxiExecPathPolicy {
    marker: string;
    binaryNames?: string[];
    distEntrypoints?: string[];
}
export interface InstallSessionStartHooksOptions {
    marker?: string;
    execPath?: string;
    binaryNames?: string[];
    distEntrypoints?: string[];
    timeoutSeconds?: number;
    homeDir?: string;
    shouldInstall?: (execPath: string) => boolean;
    onError?: (message: string) => void;
}
export interface PortableHookCommandContext {
    pathEntries: string[];
    pathExtensions: string[];
    resolveRealPath: (absolutePath: string) => string | undefined;
    resolveShimTarget?: (shimPath: string) => string | undefined;
}
export declare function computeSessionStartHookUpdate(settings: HookSettings, spec: ManagedHookSpec): [HookSettings, boolean];
export declare function computeCodexConfigUpdate(content: string): [string, boolean];
export declare function resolvePortableHookCommand(execPath: string, binaryNames: string[], marker: string, context: PortableHookCommandContext): string;
export declare function extractNpmShimScriptPath(content: string): string | undefined;
export declare function shouldInstallHooksForNodeAxiExecPath(execPath: string, policy: NodeAxiExecPathPolicy): boolean;
export declare function installSessionStartHooks(options?: InstallSessionStartHooksOptions): void;
