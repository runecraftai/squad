import type { z } from "zod";
import { parseContract, UnsupportedSchemaVersionError } from "./errors";

export function assertSupportedVersion(
  schemaName: string,
  version: number,
  supportedVersions: readonly number[],
): void {
  if (!supportedVersions.includes(version)) {
    throw new UnsupportedSchemaVersionError(
      schemaName,
      version,
      supportedVersions,
    );
  }
}

export function parseVersionedContract<
  CurrentSchema extends z.ZodType,
  LegacySchema extends z.ZodType,
>(
  schemaName: string,
  current: { version: number; schema: CurrentSchema },
  legacy: {
    version: number;
    schema: LegacySchema;
    migrate: (value: z.infer<LegacySchema>) => z.infer<CurrentSchema>;
  },
  input: unknown,
): z.infer<CurrentSchema> {
  const versionField = (input as { schemaVersion?: unknown } | null)
    ?.schemaVersion;
  if (versionField === current.version) {
    return parseContract(schemaName, current.schema, input);
  }
  if (versionField === legacy.version) {
    const legacyValue = parseContract(
      `${schemaName}.legacy`,
      legacy.schema,
      input,
    );
    return legacy.migrate(legacyValue);
  }
  const receivedVersion = typeof versionField === "number" ? versionField : -1;
  throw new UnsupportedSchemaVersionError(schemaName, receivedVersion, [
    legacy.version,
    current.version,
  ]);
}
