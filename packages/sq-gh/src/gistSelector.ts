import { AxiError } from "./errors.js";
import { resolveHost } from "./host.js";

/**
 * Convert a bare gist id or a gist URL to a bare id.
 *
 * Accepts three URL shapes:
 *   gist.github.com/OWNER/ID       (owner-scoped)
 *   gist.github.com/ID             (ownerless)
 *   ghe.example.com/gist/OWNER/ID  (GHE — last segment is always the id)
 *
 * Takes the **last non-empty path segment** across all shapes. gh's own
 * GistIDFromURL takes path segment index 2, which returns OWNER for the GHE
 * shape — that is wrong. Last-segment handles all three correctly.
 *
 * The URL's host is validated against the configured host (GH_HOST > github.com).
 * Both `<host>` and `gist.<host>` are accepted as valid origins.
 */
export function gistIdFromSelector(selector: string): string {
  const trimmed = selector.trim();

  if (!trimmed) {
    throw new AxiError("Gist selector must not be empty", "VALIDATION_ERROR");
  }

  if (/\s/.test(trimmed)) {
    throw new AxiError(
      `Gist selector must not contain whitespace: "${selector.trim()}"`,
      "VALIDATION_ERROR",
    );
  }

  if (trimmed.startsWith("https://") || trimmed.startsWith("http://")) {
    return extractIdFromUrl(trimmed);
  }

  // Bare id — validate its charset before it is interpolated into the
  // `/gists/<id>` API path, so a malformed selector can never traverse the path.
  return validateBareId(trimmed);
}

// A gist id is alphanumeric. Reject anything else (slashes, dot-segments, etc.)
// that could alter the API path it gets interpolated into.
function validateBareId(id: string): string {
  if (!/^[A-Za-z0-9]+$/.test(id)) {
    throw new AxiError(`Invalid gist id: "${id}"`, "VALIDATION_ERROR", [
      "A gist id is alphanumeric; pass a bare id or a full gist URL",
    ]);
  }
  return id;
}

function extractIdFromUrl(rawUrl: string): string {
  let url: URL;
  try {
    url = new URL(rawUrl);
  } catch {
    throw new AxiError(`Malformed gist URL: ${rawUrl}`, "VALIDATION_ERROR");
  }
  const hostname = url.hostname;

  // Accept <configured> or gist.<configured>.
  const configured = resolveHost();
  const validHosts = new Set([configured, `gist.${configured}`]);
  if (!validHosts.has(hostname)) {
    throw new AxiError(
      `Gist URL host "${hostname}" does not match the configured host "${configured}"`,
      "VALIDATION_ERROR",
    );
  }

  // Take the last non-empty path segment — correct for all URL shapes.
  const segments = url.pathname.split("/").filter(Boolean);
  const id = segments[segments.length - 1];
  if (!id) {
    throw new AxiError(
      `Could not extract a gist id from URL: ${rawUrl}`,
      "VALIDATION_ERROR",
    );
  }

  // The extracted segment also lands in the `/gists/<id>` API path, so hold it
  // to the same charset as a bare id (blocks `..`, encoded slashes, etc.).
  return validateBareId(id);
}
