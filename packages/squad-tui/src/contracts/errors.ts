import type { z } from "zod";

export class ContractValidationError extends Error {
  readonly code = "contract_validation_error";
  readonly schemaName: string;
  readonly issues: z.ZodError["issues"];

  constructor(schemaName: string, error: z.ZodError) {
    super(
      `${schemaName}: ${error.issues
        .map((issue) => `${issue.path.join(".") || "<root>"}: ${issue.message}`)
        .join("; ")}`,
    );
    this.name = "ContractValidationError";
    this.schemaName = schemaName;
    this.issues = error.issues;
  }
}

export class UnsupportedSchemaVersionError extends Error {
  readonly code = "unsupported_schema_version_error";
  readonly schemaName: string;
  readonly receivedVersion: number;
  readonly supportedVersions: readonly number[];

  constructor(
    schemaName: string,
    receivedVersion: number,
    supportedVersions: readonly number[],
  ) {
    super(
      `${schemaName}: schemaVersion ${receivedVersion} is not supported (supported: ${supportedVersions.join(", ")})`,
    );
    this.name = "UnsupportedSchemaVersionError";
    this.schemaName = schemaName;
    this.receivedVersion = receivedVersion;
    this.supportedVersions = supportedVersions;
  }
}

export class CorrelationMismatchError extends Error {
  readonly code = "correlation_mismatch_error";
  readonly expectedId: string;
  readonly receivedId: string;

  constructor(context: string, expectedId: string, receivedId: string) {
    super(
      `${context}: expected correlation id ${expectedId}, received ${receivedId}`,
    );
    this.name = "CorrelationMismatchError";
    this.expectedId = expectedId;
    this.receivedId = receivedId;
  }
}

export function parseContract<Schema extends z.ZodType>(
  schemaName: string,
  schema: Schema,
  input: unknown,
): z.infer<Schema> {
  const result = schema.safeParse(input);
  if (!result.success) {
    throw new ContractValidationError(schemaName, result.error);
  }
  return result.data;
}
