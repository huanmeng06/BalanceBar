#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

export const RELEASE_INPUT_LIMITS = Object.freeze({
  maxSerializedBytes: 256_000,
  maxPullRequests: 1_000,
  maxCommits: 300,
  maxCompareFiles: 300,
  maxPullRequestTitle: 300,
  maxPullRequestBody: 6_000,
  maxPullRequestLabels: 20,
  maxPullRequestFiles: 80,
  maxPullRequestFilePath: 300,
  maxImplementationSummary: 3_000,
  maxDiffSummary: 8_000,
  maxIssuesPerPullRequest: 20,
  maxIssueTitle: 300,
  maxIssueBody: 5_000,
  maxIssueLabels: 20,
  maxIssueComments: 3,
  maxIssueCommentBody: 1_000,
});

function parseArguments(argv) {
  const options = {};
  for (let index = 0; index < argv.length; index += 1) {
    const key = argv[index];
    if (!key.startsWith("--")) {
      continue;
    }
    const value = argv[index + 1];
    options[key.slice(2)] = value;
    index += 1;
  }
  return options;
}

function readJson(filePath, fallback) {
  if (!filePath || !fs.existsSync(filePath)) {
    return fallback;
  }
  return JSON.parse(fs.readFileSync(filePath, "utf8"));
}

export function truncate(value, limit) {
  if (typeof value !== "string" || limit <= 0) {
    return "";
  }
  const normalised = value.replaceAll("\u0000", "").trim();
  if (normalised.length <= limit) {
    return normalised;
  }
  if (limit === 1) {
    return "…";
  }
  return `${normalised.slice(0, limit - 1)}…`;
}

function numberOrNull(value) {
  if (value === null || value === undefined || value === "") {
    return null;
  }
  return Number.isInteger(Number(value)) && Number(value) >= 0 ? Number(value) : null;
}

function normaliseLabels(labels, limit = RELEASE_INPUT_LIMITS.maxPullRequestLabels) {
  return [...new Set((Array.isArray(labels) ? labels : [])
    .map((label) => (typeof label === "string" ? label : label?.name))
    .filter((label) => typeof label === "string" && label.trim().length > 0)
    .map((label) => truncate(label, 120))
    .filter(Boolean))]
    .slice(0, limit);
}

function issueNumber(issue) {
  const number = Number(issue?.number ?? issue);
  return Number.isInteger(number) && number > 0 ? number : null;
}

function issueDetailsMap(issueDetails) {
  const values = Array.isArray(issueDetails)
    ? issueDetails
    : issueDetails && typeof issueDetails === "object"
      ? Object.values(issueDetails)
      : [];
  return new Map(values
    .map((issue) => [issueNumber(issue), issue])
    .filter(([number]) => number !== null));
}

function canonicalPullRequestUrl(repo, number) {
  return `https://github.com/${repo}/pull/${number}`;
}

function canonicalIssueUrl(repo, number) {
  return `https://github.com/${repo}/issues/${number}`;
}

function normaliseUrl(value) {
  return typeof value === "string" ? truncate(value, 300) || null : null;
}

function normaliseComment(comment) {
  const body = truncate(comment?.body, RELEASE_INPUT_LIMITS.maxIssueCommentBody);
  if (!body) {
    return null;
  }
  return { body };
}

export function normaliseIssue(repo, issue, issueDetails = new Map()) {
  const number = issueNumber(issue);
  if (number === null) {
    return null;
  }

  const details = issueDetails instanceof Map
    ? issueDetails.get(number)
    : issueDetailsMap(issueDetails).get(number);
  const source = details ?? issue ?? {};
  const comments = (Array.isArray(source.comments) ? source.comments : [])
    .map(normaliseComment)
    .filter(Boolean)
    .slice(0, RELEASE_INPUT_LIMITS.maxIssueComments);

  return {
    number,
    title: truncate(source.title ?? issue?.title, RELEASE_INPUT_LIMITS.maxIssueTitle),
    body: truncate(source.body ?? issue?.body, RELEASE_INPUT_LIMITS.maxIssueBody),
    url: canonicalIssueUrl(repo, number),
    labels: normaliseLabels(source.labels ?? issue?.labels, RELEASE_INPUT_LIMITS.maxIssueLabels),
    comments,
  };
}

function normaliseFile(file) {
  const filePath = truncate(file?.filename ?? file?.path, RELEASE_INPUT_LIMITS.maxPullRequestFilePath);
  if (!filePath) {
    return null;
  }
  return {
    path: filePath,
    status: truncate(file?.status ?? file?.changeType, 40),
    additions: numberOrNull(file?.additions),
    deletions: numberOrNull(file?.deletions),
  };
}

function normaliseCommit(commit) {
  const rawSha = commit?.oid ?? commit?.sha;
  if (typeof rawSha !== "string" || !rawSha) {
    return null;
  }
  const message = commit?.subject
    ?? commit?.message
    ?? commit?.commit?.message?.split("\n", 1)[0];
  return {
    sha: truncate(rawSha, 100),
    subject: truncate(message, 300),
    url: normaliseUrl(commit?.url ?? commit?.html_url),
  };
}

export function normalisePullRequest(repo, pullRequest, issueDetails = new Map()) {
  const number = Number(pullRequest?.number);
  if (!Number.isInteger(number) || number <= 0) {
    return null;
  }

  const labels = normaliseLabels(pullRequest.labels);
  const issues = (Array.isArray(pullRequest.closingIssuesReferences)
    ? pullRequest.closingIssuesReferences
    : [])
    .map((issue) => normaliseIssue(repo, issue, issueDetails))
    .filter(Boolean);
  const uniqueIssues = [...new Map(issues.map((issue) => [issue.number, issue])).values()]
    .slice(0, RELEASE_INPUT_LIMITS.maxIssuesPerPullRequest);
  const commits = (Array.isArray(pullRequest.commits) ? pullRequest.commits : [])
    .map(normaliseCommit)
    .filter(Boolean)
    .slice(0, RELEASE_INPUT_LIMITS.maxCommits);
  const commitShas = commits.length > 0
    ? [...new Set(commits.map((commit) => commit.sha))]
    : [...new Set((Array.isArray(pullRequest.commitShas) ? pullRequest.commitShas : [])
      .filter((sha) => typeof sha === "string")
      .map((sha) => truncate(sha, 100)))]
      .slice(0, RELEASE_INPUT_LIMITS.maxCommits);
  const files = (Array.isArray(pullRequest.files) ? pullRequest.files : [])
    .map(normaliseFile)
    .filter(Boolean)
    .slice(0, RELEASE_INPUT_LIMITS.maxPullRequestFiles);
  const rawMergeCommit = pullRequest.mergeCommit?.oid
    ?? pullRequest.merge_commit_sha
    ?? pullRequest.mergeCommit;
  const result = {
    number,
    title: truncate(pullRequest.title, RELEASE_INPUT_LIMITS.maxPullRequestTitle),
    body: truncate(pullRequest.body, RELEASE_INPUT_LIMITS.maxPullRequestBody),
    url: canonicalPullRequestUrl(repo, number),
    mergedAt: truncate(pullRequest.mergedAt, 80) || null,
    mergeCommit: typeof rawMergeCommit === "string" ? truncate(rawMergeCommit, 100) : null,
    commitShas,
    labels,
    changedFiles: numberOrNull(pullRequest.changedFiles) ?? files.length,
    additions: numberOrNull(pullRequest.additions),
    deletions: numberOrNull(pullRequest.deletions),
    files,
    closingIssues: uniqueIssues,
  };

  const implementationSummary = truncate(
    pullRequest.implementationSummary,
    RELEASE_INPUT_LIMITS.maxImplementationSummary,
  );
  const diffSummary = truncate(
    pullRequest.diffSummary ?? pullRequest.patch,
    RELEASE_INPUT_LIMITS.maxDiffSummary,
  );
  if (implementationSummary) {
    result.implementationSummary = implementationSummary;
  }
  if (diffSummary) {
    result.diffSummary = diffSummary;
  }
  if (commits.length > 0) {
    result.commits = commits;
  }

  return result;
}

export function tagVersion(tag) {
  const match = /^v?(\d+\.\d+\.\d+)(?:-.+)?$/.exec(tag ?? "");
  return match ? match[1] : "0.0.0";
}

export function pullRequestsInRange({ pullRequests, compare, eventPullRequest }) {
  const compareCommitShas = new Set(
    (compare?.commits ?? []).map((commit) => commit.sha).filter(Boolean),
  );
  const eventNumber = Number(eventPullRequest?.number);

  const selected = pullRequests.filter((pullRequest) => {
    const mergeCommit = pullRequest.mergeCommit?.oid ?? pullRequest.mergeCommit;
    return Number(pullRequest.number) === eventNumber
      || (mergeCommit && compareCommitShas.has(mergeCommit))
      || (pullRequest.commitShas ?? []).some((sha) => compareCommitShas.has(sha));
  });

  if (selected.length > 0) {
    return selected;
  }

  return eventPullRequest ? [eventPullRequest] : [];
}

function cloneJson(value) {
  return JSON.parse(JSON.stringify(value));
}

export function serializedByteLength(value) {
  return Buffer.byteLength(JSON.stringify(value), "utf8");
}

function compactReleaseInputAtLevel(input, level) {
  const limits = [
    { prBody: 6_000, issueBody: 5_000, diff: 8_000, implementation: 3_000, files: 80, comments: 3 },
    { prBody: 2_500, issueBody: 1_800, diff: 2_500, implementation: 1_200, files: 40, comments: 1 },
    { prBody: 900, issueBody: 600, diff: 800, implementation: 400, files: 15, comments: 0 },
    { prBody: 250, issueBody: 250, diff: 0, implementation: 0, files: 8, comments: 0 },
    { prBody: 0, issueBody: 0, diff: 0, implementation: 0, files: 0, comments: 0 },
  ][level];

  const result = cloneJson(input);
  result.issues = (result.issues ?? []).map((issue) => ({
    ...(typeof issue === "object" && issue !== null ? issue : { number: issueNumber(issue) }),
    body: truncate(issue?.body, limits.issueBody),
    comments: (issue?.comments ?? []).slice(0, limits.comments),
  }));
  result.pullRequests = (result.pullRequests ?? []).map((pullRequest) => {
    const compacted = {
      ...pullRequest,
      body: truncate(pullRequest.body, limits.prBody),
      files: (pullRequest.files ?? []).slice(0, limits.files),
      closingIssues: (pullRequest.closingIssues ?? []).map((issue) => ({
        ...(typeof issue === "object" && issue !== null ? issue : { number: issueNumber(issue) }),
        body: truncate(issue?.body, limits.issueBody),
        comments: (issue?.comments ?? []).slice(0, limits.comments),
      })),
    };
    if (limits.diff === 0) {
      delete compacted.diffSummary;
    } else {
      compacted.diffSummary = truncate(compacted.diffSummary, limits.diff);
    }
    if (limits.implementation === 0) {
      delete compacted.implementationSummary;
    } else {
      compacted.implementationSummary = truncate(compacted.implementationSummary, limits.implementation);
    }
    return compacted;
  });
  result.commits = (result.commits ?? []).slice(0, level >= 3 ? 120 : RELEASE_INPUT_LIMITS.maxCommits);
  result.files = (result.files ?? []).slice(0, level >= 3 ? 80 : RELEASE_INPUT_LIMITS.maxCompareFiles);
  return result;
}

function minimumReleaseInput(input) {
  const result = cloneJson(input);
  result.issues = (result.issues ?? []).map((issue) => ({
    number: issueNumber(issue),
    title: truncate(issue?.title, 120),
  })).filter((issue) => issue.number !== null);
  result.pullRequests = (result.pullRequests ?? []).map((pullRequest) => ({
    number: pullRequest.number,
    title: truncate(pullRequest.title, 120),
    closingIssues: (pullRequest.closingIssues ?? [])
      .map((issue) => issueNumber(issue))
      .filter((number) => number !== null),
  }));
  result.commits = [];
  result.files = [];
  return result;
}

export function limitReleaseInput(input, maxBytes = RELEASE_INPUT_LIMITS.maxSerializedBytes) {
  let result = cloneJson(input);
  if (serializedByteLength(result) <= maxBytes) {
    return result;
  }

  for (let level = 0; level < 5; level += 1) {
    result = compactReleaseInputAtLevel(result, level);
    if (serializedByteLength(result) <= maxBytes) {
      return result;
    }
  }

  result = minimumReleaseInput(result);
  return serializedByteLength(result) <= maxBytes ? result : compactReleaseInputAtLevel(result, 4);
}

export function getReleaseInputStats(input) {
  const issueNumbers = new Set((input?.issues ?? [])
    .map(issueNumber)
    .filter((number) => number !== null));
  const filePaths = new Set();
  for (const pullRequest of input?.pullRequests ?? []) {
    for (const issue of pullRequest.closingIssues ?? []) {
      const number = issueNumber(issue);
      if (number !== null) {
        issueNumbers.add(number);
      }
    }
    for (const file of pullRequest.files ?? []) {
      const filePath = typeof file === "string" ? file : file?.path ?? file?.filename;
      if (filePath) {
        filePaths.add(filePath);
      }
    }
  }
  for (const file of input?.files ?? []) {
    const filePath = typeof file === "string" ? file : file?.path ?? file?.filename;
    if (filePath) {
      filePaths.add(filePath);
    }
  }
  return {
    pullRequests: input?.pullRequests?.length ?? 0,
    issues: issueNumbers.size,
    commits: input?.commits?.length ?? 0,
    files: filePaths.size,
  };
}

export function buildReleaseInput({
  event,
  compare = {},
  pullRequests = [],
  issues = [],
  repo,
  previousTag,
  currentSha,
  version,
  tag,
}) {
  const issueDetails = issueDetailsMap(issues);
  const eventPullRequest = normalisePullRequest(repo, event?.pull_request, issueDetails);
  const normalisedPullRequests = pullRequests
    .map((pullRequest) => normalisePullRequest(repo, pullRequest, issueDetails))
    .filter(Boolean);
  const selectedPullRequests = pullRequestsInRange({
    pullRequests: normalisedPullRequests,
    compare,
    eventPullRequest,
  });
  const deduplicatedPullRequests = [
    ...new Map(selectedPullRequests.map((pullRequest) => [pullRequest.number, pullRequest])).values(),
  ].sort((left, right) => left.number - right.number);
  const issueCatalog = [
    ...new Map(deduplicatedPullRequests
      .flatMap((pullRequest) => pullRequest.closingIssues ?? [])
      .map((issue) => [issueNumber(issue), issue])
      .filter(([number]) => number !== null)).values(),
  ].sort((left, right) => left.number - right.number);
  const pullRequestsWithIssueReferences = deduplicatedPullRequests.map((pullRequest) => ({
    ...pullRequest,
    closingIssues: (pullRequest.closingIssues ?? []).map((issue) => ({
      number: issue.number,
      title: issue.title,
      url: issue.url,
    })),
  }));

  const commits = (compare.commits ?? [])
    .map(normaliseCommit)
    .filter(Boolean)
    .slice(0, RELEASE_INPUT_LIMITS.maxCommits);
  const files = (compare.files ?? [])
    .map(normaliseFile)
    .filter(Boolean)
    .slice(0, RELEASE_INPUT_LIMITS.maxCompareFiles);
  const compareUrl = `https://github.com/${repo}/compare/${previousTag}...${tag}`;

  return limitReleaseInput({
    repo,
    currentSha,
    version,
    tag,
    previousTag,
    previousVersion: tagVersion(previousTag),
    compareUrl,
    pullRequests: pullRequestsWithIssueReferences,
    issues: issueCatalog,
    commits,
    files,
  });
}

function writeJson(filePath, value) {
  if (filePath) {
    fs.writeFileSync(filePath, `${JSON.stringify(value, null, 2)}\n`);
  }
}

function main() {
  const options = parseArguments(process.argv.slice(2));
  const event = readJson(options.event, {});
  const compare = readJson(options.compare, {});
  const pullRequests = readJson(options.prs, []);
  const issues = readJson(options.issues, []);
  const input = buildReleaseInput({
    event,
    compare,
    pullRequests,
    issues,
    repo: options.repo ?? process.env.GITHUB_REPOSITORY,
    previousTag: options["previous-tag"],
    currentSha: options["current-sha"],
    version: options.version,
    tag: options.tag,
  });

  if (input.pullRequests.length === 0) {
    throw new Error("No merged pull requests were found in the release range");
  }

  writeJson(
    options["selection-output"],
    input.pullRequests.map((pullRequest) => ({ number: pullRequest.number })),
  );
  writeJson(options.output, input);
  process.stdout.write(`${JSON.stringify(input, null, 2)}\n`);
}

const isMain = process.argv[1]
  && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href;

if (isMain) {
  try {
    main();
  } catch (error) {
    console.error(`collect-release-input: ${error.message}`);
    process.exitCode = 1;
  }
}
