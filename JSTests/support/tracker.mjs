import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

export const repositoryRoot = dirname(dirname(dirname(fileURLToPath(import.meta.url))));
export const trackerResourceDir = join(
  repositoryRoot,
  "Sources/CopilotProjectsCore/Resources/tracker"
);
