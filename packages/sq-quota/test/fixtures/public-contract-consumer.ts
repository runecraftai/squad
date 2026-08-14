import {
  compareModelsByRunway,
  type ModelQuotaRecord,
  type ModelsResponse,
  type SqQuotaResponse,
} from "@runecraft/sq-quota";

const quota: SqQuotaResponse = {
  generatedAt: "2026-08-05T12:00:00.000Z",
  schemaVersion: 3,
  providers: [],
};

const model: ModelQuotaRecord = {
  provider: "claude",
  id: "consumer-fixture",
  label: "Consumer fixture",
  intelligence: "high",
  quotaScopes: [],
  state: { status: "fresh", stale: false },
};

const models: ModelsResponse = {
  generatedAt: quota.generatedAt,
  schemaVersion: 1,
  catalog: { version: "2026-08-05", provenance: "consumer fixture" },
  models: [model],
};

void models;
void compareModelsByRunway(model, model);
