/**
 * Claude HUD - Custom StatusLine Script
 * Receives JSON via stdin (model, context, workspace, effort, thinking mode),
 * gathers git status (branch, dirty state, ahead/behind, worktrees, stash, operations),
 * and renders colored multi-line status to stdout.
 * Invoked every ~300ms by Claude Code.
 */

import { execSync } from "child_process";
import fs from "fs";
import path from "path";

// ── ANSI Colors ─────────────────────────────────────────────────────────────
const RESET = "\x1b[0m";
const DIM = "\x1b[2m";
const RED = "\x1b[31m";
const GREEN = "\x1b[32m";
const YELLOW = "\x1b[33m";
const BRIGHT_BLUE = "\x1b[94m";
const BRIGHT_MAGENTA = "\x1b[95m";

// 256-color palette
const MUTED = "\x1b[38;5;245m";
const PRIMARY = "\x1b[38;5;202m";
const ACCENT = "\x1b[38;5;214m";
const LINK = "\x1b[38;5;81m";
const INFO = "\x1b[38;5;75m";
const SUCCESS = "\x1b[38;5;77m";
const WARN = "\x1b[38;5;214m"; // Intentionally same as ACCENT — semantic distinction, same visual
const ERROR = "\x1b[38;5;196m";
const THINKING_COLOR = "\x1b[38;5;141m";

const colorize = (text, color) => `${color}${text}${RESET}`;

const colors = {
  model: (text) => colorize(text, ACCENT),
  project: (text) => colorize(text, PRIMARY),
  label: (text) => colorize(text, MUTED),
  dim: (text) => colorize(text, MUTED),
};

// ── Git Constants ───────────────────────────────────────────────────────────
const GIT_SYMBOLS = { NO_UPSTREAM: "(no upstream)", BEHIND: "⇣", AHEAD: "⇡", STASH: "*" };

const OPERATION_INDICATORS = [
  { files: ["rebase-merge", "rebase-apply"], state: "REBASE" },
  { files: ["MERGE_HEAD"], state: "MERGE" },
  { files: ["CHERRY_PICK_HEAD"], state: "CHERRY-PICK" },
  { files: ["REVERT_HEAD"], state: "REVERT" },
  { files: ["BISECT_LOG"], state: "BISECT" },
];

// ── Git Helpers ─────────────────────────────────────────────────────────────
// stdio: "ignore" on stderr suppresses git warnings from polluting stdout output
const execGit = (cmd, cwd, { raw = false } = {}) => {
  try {
    const result = execSync(cmd, { cwd, encoding: "utf-8", stdio: ["pipe", "pipe", "ignore"] });
    return raw ? result : result.trim();
  } catch {
    return null;
  }
};

const getGitRoot = (cwd) => execGit("git rev-parse --show-toplevel", cwd);

// In worktrees, .git is a file containing "gitdir: <path>" pointing to the real git directory
const getGitDir = (gitRoot) => {
  if (!gitRoot) return null;
  const gitPath = path.join(gitRoot, ".git");
  try {
    const stat = fs.statSync(gitPath);
    if (stat.isDirectory()) return gitPath;
    if (stat.isFile()) {
      const content = fs.readFileSync(gitPath, "utf-8").trim();
      const match = content.match(/^gitdir:\s*(.+)$/);
      if (match) {
        const dir = match[1];
        return path.isAbsolute(dir) ? dir : path.resolve(gitRoot, dir);
      }
    }
  } catch {}
  return null;
};

const getWorktreePaths = (cwd, gitRoot) => {
  const result = execGit("git worktree list --porcelain", cwd, { raw: true });
  if (!result) return [];
  const rootLower = path.normalize(gitRoot).toLowerCase();
  return result
    .split("\n")
    .filter((l) => l.startsWith("worktree "))
    .map((l) => path.normalize(l.slice(9)))
    .filter((wt) => wt.toLowerCase() !== rootLower);
};

// Parse file path from `git status --porcelain`: "XY <path>" or "XY <old> -> <new>" for renames
const extractFilePath = (line) => {
  const status = line.slice(0, 2);
  const filePart = line.slice(3);
  if (status.includes("R")) {
    const i = filePart.indexOf(" -> ");
    if (i !== -1) return filePart.slice(i + 4);
  }
  return filePart.startsWith('"') && filePart.endsWith('"') ? filePart.slice(1, -1) : filePart;
};

const getSubmodulePaths = (cwd) => {
  const result = execGit("git submodule status", cwd, { raw: true });
  if (!result) return [];
  return result
    .split("\n")
    .filter(Boolean)
    .map((l) => l.match(/^[\s+-]?[a-f0-9]+\s+(\S+)/)?.[1])
    .filter(Boolean);
};

// Parse `git status --porcelain`, excluding changes from other worktrees and submodule internals
const parseRepoStatus = (cwd, gitRoot) => {
  const status = execGit("git status --porcelain", cwd, { raw: true });
  if (!status) return { hasChanges: false, hasConflicts: false, staged: 0, unstaged: 0, untracked: 0 };

  const worktrees = getWorktreePaths(cwd, gitRoot);
  const submodules = getSubmodulePaths(cwd);
  const result = { staged: 0, unstaged: 0, untracked: 0, hasConflicts: false };

  for (const line of status.split("\n").filter(Boolean)) {
    const filePath = extractFilePath(line);

    // Skip files belonging to other worktrees
    if (worktrees.length > 0) {
      const fullPath = path.normalize(path.join(gitRoot, filePath)).toLowerCase();
      if (
        worktrees.some((wt) => {
          const wtLower = wt.toLowerCase();
          return fullPath.startsWith(wtLower + path.sep) || fullPath === wtLower;
        })
      )
        continue;
    }

    // Skip files inside submodules (but not the submodule entry itself)
    const normalized = filePath.replace(/\\/g, "/");
    if (
      !submodules.includes(normalized) &&
      submodules.some((sm) => normalized === sm || normalized.startsWith(sm + "/"))
    )
      continue;

    const x = line.charAt(0),
      y = line.charAt(1);
    if (x !== "?" && x !== " ") result.staged++;
    if (y !== "?" && y !== " ") result.unstaged++;
    if (x === "?" || y === "?") result.untracked++;
    if (line.slice(0, 2).includes("U") || line.slice(0, 2) === "AA") result.hasConflicts = true;
  }

  result.hasChanges = result.staged > 0 || result.unstaged > 0 || result.untracked > 0;
  return result;
};

const getStashCount = (cwd) => {
  const result = execGit("git stash list", cwd, { raw: true });
  return result ? result.split("\n").filter(Boolean).length : 0;
};

const getAheadBehind = (cwd, upstream) => {
  const rev = execGit(`git rev-list --left-right --count ${upstream}...HEAD`, cwd);
  if (!rev) return { ahead: 0, behind: 0 };
  // git rev-list --left-right: left=behind(upstream commits), right=ahead(local commits)
  const [behind, ahead] = rev.split("\t");
  return { ahead: parseInt(ahead, 10) || 0, behind: parseInt(behind, 10) || 0 };
};

const getLocalCommitCount = (cwd) => {
  const result = execGit("git rev-list --count HEAD", cwd);
  return parseInt(result, 10) || 0;
};

const getOperationState = (gitRoot) => {
  const gitDir = getGitDir(gitRoot);
  if (!gitDir) return null;
  return (
    OPERATION_INDICATORS.find(({ files }) => files.some((f) => fs.existsSync(path.join(gitDir, f))))?.state ?? null
  );
};

const getBranchName = (cwd, gitRoot) => {
  const branch = execGit("git rev-parse --abbrev-ref HEAD", cwd);
  if (!branch) {
    // Fallback: read HEAD file directly
    const gitDir = getGitDir(gitRoot);
    if (!gitDir) return null;
    try {
      const head = fs.readFileSync(path.join(gitDir, "HEAD"), "utf-8").trim();
      return head.match(/^ref:\s*refs\/heads\/(.+)$/)?.[1] ?? null;
    } catch {
      return null;
    }
  }
  if (branch !== "HEAD") return branch;

  const tag = execGit("git describe --tags --exact-match HEAD", cwd);
  if (tag) return `tag:${tag}`;

  const hash = execGit("git rev-parse --short HEAD", cwd);
  return hash ? `:${hash}` : null;
};

const buildGitStatus = (branch, stash, ab, files, branchColor, hasUpstream, opState, localCommits) => {
  const parts = [colorize(branch, branchColor)];

  if (!hasUpstream) parts.push(colorize(GIT_SYMBOLS.NO_UPSTREAM, MUTED));
  if (opState) parts.push(colorize(opState, ERROR));
  if (stash > 0) parts.push(colorize(`${GIT_SYMBOLS.STASH}${stash}`, SUCCESS));

  if (hasUpstream) {
    if (ab.behind > 0) parts.push(colorize(`${GIT_SYMBOLS.BEHIND}${ab.behind}`, INFO));
    if (ab.ahead > 0) parts.push(colorize(`${GIT_SYMBOLS.AHEAD}${ab.ahead}`, INFO));
  } else if (localCommits > 0) {
    parts.push(colorize(`${GIT_SYMBOLS.AHEAD}${localCommits}`, INFO));
  }

  if (files.staged > 0) parts.push(colorize(`+${files.staged}`, WARN));
  if (files.unstaged > 0) parts.push(colorize(`!${files.unstaged}`, WARN));
  if (files.untracked > 0) parts.push(colorize(`?${files.untracked}`, LINK));

  return parts.join(" ");
};

const getGitInfo = (cwd) => {
  const gitRoot = getGitRoot(cwd);
  if (!gitRoot) return "";

  const branch = getBranchName(cwd, gitRoot);
  if (!branch) return "";

  const repoStatus = parseRepoStatus(cwd, gitRoot);
  const upstream = execGit("git rev-parse --abbrev-ref --symbolic-full-name @{u}", cwd);
  const hasUpstream = !!upstream;
  const branchColor = repoStatus.hasConflicts ? ERROR : repoStatus.hasChanges ? WARN : SUCCESS;

  return buildGitStatus(
    branch,
    getStashCount(cwd),
    hasUpstream ? getAheadBehind(cwd, upstream) : { ahead: 0, behind: 0 },
    repoStatus,
    branchColor,
    hasUpstream,
    getOperationState(gitRoot),
    hasUpstream ? 0 : getLocalCommitCount(cwd),
  );
};

// ── Display Helpers ─────────────────────────────────────────────────────────
const getFolderDisplay = (cwd) => {
  const folder = path.basename(cwd);
  const gitRoot = getGitRoot(cwd);
  if (!gitRoot || path.normalize(cwd).toLowerCase() === path.normalize(gitRoot).toLowerCase()) {
    return colors.project(folder);
  }
  return `${colors.project(folder)} ${colors.dim("→")} ${colors.dim(path.basename(gitRoot))}`;
};

// Modes: "context" (green→yellow→red at 70%/85%) or "quota" (blue→magenta→red at 75%/90%)
function getProgressBar(percent, width = 10, mode = "context") {
  const p = Math.min(100, Math.max(0, percent || 0));
  const filled = Math.round((p / 100) * width);
  const color =
    mode === "quota"
      ? p >= 90
        ? RED
        : p >= 75
          ? BRIGHT_MAGENTA
          : BRIGHT_BLUE
      : p >= 85
        ? RED
        : p >= 70
          ? YELLOW
          : GREEN;
  const pctText = mode === "quota" ? `${color}${p}%${RESET}` : `${p}%`;
  return `${color}${"█".repeat(filled)}${DIM}${"░".repeat(width - filled)}${RESET} ${pctText}`;
}

// ── Usage / Rate Limit Display ──────────────────────────────────────────────
// Parses 5-hour and 7-day rate limits from stdin, renders quota progress bars.

/**
 * Format a reset timestamp as relative duration (e.g. "2h 30m", "45m", "1d 3h").
 * Returns empty string if resetAt is null or in the past.
 */
function formatResetTime(resetAt) {
  if (!resetAt) return "";
  const diffMs = resetAt.getTime() - Date.now();
  if (diffMs <= 0) return "";

  const diffMins = Math.ceil(diffMs / 60000);
  if (diffMins < 60) return `${diffMins}m`;

  const hours = Math.floor(diffMins / 60);
  const mins = diffMins % 60;

  if (hours >= 24) {
    const days = Math.floor(hours / 24);
    const remHours = hours % 24;
    return remHours > 0 ? `${days}d ${remHours}h` : `${days}d`;
  }

  return mins > 0 ? `${hours}h ${mins}m` : `${hours}h`;
}

/**
 * Render a single rate-limit window as a display string.
 * Returns "⚠ <label> Limit (Xh Ym)" at 100%, a bar at threshold+, or null.
 */
function renderUsageWindow(label, percent, resetAt, threshold = 0) {
  if (percent === null) return null;

  if (percent === 100) {
    const reset = formatResetTime(resetAt);
    const resetSuffix = reset ? ` (${reset})` : "";
    return `${RED}⚠ ${label} Limit${resetSuffix}${RESET}`;
  }

  if (percent < threshold) return null;

  const bar = getProgressBar(percent, 10, "quota");
  const reset = formatResetTime(resetAt);
  const resetSuffix = reset ? ` ${MUTED}(${reset})${RESET}` : "";
  return `${MUTED}${label}:${RESET} ${bar}${resetSuffix}`;
}

/**
 * Extract and render 5h / 7d rate-limit displays from parsed input data.
 * sevenDayThreshold controls the minimum percent at which the 7d bar appears.
 */
function getUsageDisplays(data, sevenDayThreshold = 80) {
  const rateLimits = data.rate_limits;
  if (!rateLimits) return { fiveHour: null, sevenDay: null };

  const parse = (v) => (typeof v === "number" && Number.isFinite(v) ? Math.round(Math.min(100, Math.max(0, v))) : null);
  const parseReset = (v) => (typeof v === "number" && Number.isFinite(v) && v > 0 ? new Date(v * 1000) : null);

  const fiveHourPct = parse(rateLimits.five_hour?.used_percentage);
  const sevenDayPct = parse(rateLimits.seven_day?.used_percentage);
  if (fiveHourPct === null && sevenDayPct === null) return { fiveHour: null, sevenDay: null };

  return {
    fiveHour: renderUsageWindow("5h", fiveHourPct, parseReset(rateLimits.five_hour?.resets_at)),
    sevenDay: renderUsageWindow("7d", sevenDayPct, parseReset(rateLimits.seven_day?.resets_at), sevenDayThreshold),
  };
}

// ── Effort Display ──────────────────────────────────────────────────────────
const EFFORT_LEVELS = {
  low: { symbol: "○", color: "\x1b[38;5;245m" },
  medium: { symbol: "◐", color: "\x1b[38;5;114m" },
  high: { symbol: "●", color: "\x1b[38;5;75m" },
  xhigh: { symbol: "◉", color: "\x1b[38;5;141m" },
  max: { symbol: "◈", color: "\x1b[38;5;196m" },
};

function getEffortDisplay(effortField) {
  const level = (typeof effortField === "string" ? effortField : effortField?.level)?.toLowerCase().trim();
  if (!level) return "";
  const { symbol = "", color = MUTED } = EFFORT_LEVELS[level] ?? {};
  const text = symbol ? `${symbol} ${level}` : level;
  return `${color}${text}${RESET}`;
}

// ── Main Render ─────────────────────────────────────────────────────────────
const processInput = (chunks) => {
  try {
    const data = JSON.parse(chunks);

    const modelName = data.model?.display_name;
    const workDir = data.workspace?.current_dir || data.cwd || process.cwd();
    const addedDirs = data.workspace?.added_dirs || [];
    const outputStyle = data.output_style?.name !== "default" ? data.output_style?.name || "" : ""; // Hide "default" style — only show non-standard output styles
    const usedPct = data.context_window?.used_percentage || "";
    const thinking = data.thinking?.enabled ? "Thinking" : "";
    const effort = getEffortDisplay(data.effort);
    const contextBar = usedPct ? getProgressBar(usedPct) : "";
    const gitInfo = getGitInfo(workDir);
    const usage = getUsageDisplays(data, 80);

    // Output layout:
    //   Line 1: model | project folder | git status
    //   Line 2: thinking | effort | output style | context bar | 5h usage | 7d usage
    //   Line 3: additional workspace directories joined by | (if any)
    const lines = [
      [modelName ? colors.model(modelName) : "", workDir ? getFolderDisplay(workDir) : "", gitInfo],
      [
        thinking ? colorize(thinking, THINKING_COLOR) : "",
        effort,
        outputStyle ? colors.label(outputStyle) : "",
        contextBar,
        usage.fiveHour || "",
        usage.sevenDay || "",
      ],
      addedDirs.map((d) => colors.dim(d)),
    ];

    lines
      .map((parts) => parts.filter(Boolean).join(" | "))
      .filter(Boolean)
      .forEach((line) => console.log(line));
  } catch {
    console.log("");
  }
};

// Buffer all stdin chunks before parsing — JSON may arrive across multiple reads
let chunks = "";
process.stdin.on("readable", () => {
  let chunk;
  while ((chunk = process.stdin.read()) !== null) chunks += chunk;
});
process.stdin.on("end", () => processInput(chunks));
