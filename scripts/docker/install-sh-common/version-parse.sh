#!/usr/bin/env bash

extract_openclaw_semver() {
  local raw="${1:-}"
  raw="${raw//$'\r'/}"
  if [[ "$raw" =~ v?([0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z]+(\.[0-9A-Za-z]+)*)?(\+[0-9A-Za-z.-]+)?) ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
}

quiet_npm() {
  npm \
    --loglevel=error \
    --logs-max=0 \
    --no-update-notifier \
    --no-fund \
    --no-audit \
    --no-progress \
    "$@"
}

resolve_openclaw_update_baseline_version() {
  local package_name="${1:-}"
  local candidate_version="${2:-}"
  local requested_baseline="${3:-latest}"
  if [[ -z "$package_name" || -z "$candidate_version" || "$requested_baseline" != "latest" ]]; then
    printf '%s' "$requested_baseline"
    return 0
  fi

  local versions_json
  versions_json="$(quiet_npm view "$package_name" versions --json 2>/dev/null || true)"
  if [[ -z "$versions_json" ]]; then
    printf '%s' "$requested_baseline"
    return 0
  fi

  PACKAGE_NAME="$package_name" \
    CANDIDATE_VERSION="$candidate_version" \
    VERSIONS_JSON="$versions_json" \
    node - <<'NODE'
const candidateVersion = String(process.env.CANDIDATE_VERSION || "").trim();
const raw = process.env.VERSIONS_JSON || "[]";

function parseVersion(input) {
  const match =
    /^v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$/u.exec(input.trim());
  if (!match) {
    return null;
  }
  return {
    raw: input.trim(),
    major: Number.parseInt(match[1], 10),
    minor: Number.parseInt(match[2], 10),
    patch: Number.parseInt(match[3], 10),
    prerelease: match[4] ? match[4].split(".") : [],
  };
}

function compareIdentifiers(left, right) {
  const leftIsNumeric = /^\d+$/u.test(left);
  const rightIsNumeric = /^\d+$/u.test(right);
  if (leftIsNumeric && rightIsNumeric) {
    return Number.parseInt(left, 10) - Number.parseInt(right, 10);
  }
  if (leftIsNumeric) {
    return -1;
  }
  if (rightIsNumeric) {
    return 1;
  }
  return left.localeCompare(right);
}

function compareVersions(left, right) {
  for (const key of ["major", "minor", "patch"]) {
    if (left[key] !== right[key]) {
      return left[key] - right[key];
    }
  }
  const leftPrerelease = left.prerelease;
  const rightPrerelease = right.prerelease;
  if (leftPrerelease.length === 0 && rightPrerelease.length === 0) {
    return 0;
  }
  if (leftPrerelease.length === 0) {
    return 1;
  }
  if (rightPrerelease.length === 0) {
    return -1;
  }
  const maxLength = Math.max(leftPrerelease.length, rightPrerelease.length);
  for (let index = 0; index < maxLength; index += 1) {
    const leftPart = leftPrerelease[index];
    const rightPart = rightPrerelease[index];
    if (leftPart === undefined) {
      return -1;
    }
    if (rightPart === undefined) {
      return 1;
    }
    const diff = compareIdentifiers(leftPart, rightPart);
    if (diff !== 0) {
      return diff;
    }
  }
  return 0;
}

let parsedVersions;
try {
  parsedVersions = JSON.parse(raw);
} catch {
  parsedVersions = raw ? [raw] : [];
}
if (!Array.isArray(parsedVersions)) {
  parsedVersions = [parsedVersions];
}

const candidate = parseVersion(candidateVersion);
if (!candidate) {
  process.stdout.write("latest");
  process.exit(0);
}
const candidateIsStable = candidate.prerelease.length === 0;

let bestOlder = null;
let bestNotNewer = null;
for (const entry of parsedVersions) {
  if (typeof entry !== "string") {
    continue;
  }
  const parsed = parseVersion(entry);
  if (!parsed) {
    continue;
  }
  if (candidateIsStable && parsed.prerelease.length > 0) {
    continue;
  }
  const diff = compareVersions(parsed, candidate);
  if (diff < 0 && (!bestOlder || compareVersions(parsed, bestOlder) > 0)) {
    bestOlder = parsed;
  }
  if (diff <= 0 && (!bestNotNewer || compareVersions(parsed, bestNotNewer) > 0)) {
    bestNotNewer = parsed;
  }
}

process.stdout.write((bestOlder ?? bestNotNewer)?.raw ?? "latest");
NODE
}
