// Negative fixture: a core module that reaches into the Squad adapter. The dependency-direction checker must reject
// it. Never compiled or imported; tsconfig includes only src/.
import { SQUAD_NAMESPACE } from "../../../src/adapter/squad.js";
import { parseMissionId } from "./helpers.js";

export const namespace = SQUAD_NAMESPACE;
export const parse = parseMissionId;
