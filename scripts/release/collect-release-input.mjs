#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

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

function truncate(value, limit) {
  if (typeof value !== "string") {
    return "";
  }
  const normalised = value.replaceAll("\u0000", "").trim();
  return normalised.length <= limit
    ? normalised
    : `${normalised.slice(0, limit)}…`;
}

function tagVersion(tag) {
  const match = /^v?(\d+\.\d+\.\d+)(?:-.+)?$/.exec(tag ?? "");
  return match ? match[1] : "0.0.0";
}

function canonicalPullRequestUrl(repo, number) {
  return `https://github.com/${repo}/pull/${number}`;
}

function canonicalIssueUrl(repo, number) {
  return `https://github.com/${repo}/issues/${number}`;
}

function normaliseIssue(repo, issue) {
  const number = Number(issue?.number ?? issue);
  if (!Number.isInteger(number) || number <= 0) {
    return null;
  }

  return {
    number,
    title: truncate(issue?.title, 300),
    url: canonicalIssueUrl(repo, number),
  };
}

function normalisePullRequest(repo, pullRequest) {
  const number = Number(pullRequest?.number);
  if (!Number.isInteger(number) || number <= 0) {
    return null;
  }

  const labels = (pullRequest.labels ?? [])
    .map((label) => (typeof label === "string" ? label : label?.name))
    .filter(Boolean);
  const issues = (pullRequest.closingIssuesReferences ?? [])
    .map((issue) => normaliseIssue(repo, issue))
    .filter(Boolean);
  const uniqueIssues = [...new Map(issues.map((issue) => [issue.number, issue])).values()];
  const commitShas = (Array.isArray(pullRequest.commits) ? pullRequest.commits : [])
    .map((commit) => commit?.oid ?? commit?.sha)
    .filter(Boolean);

  return {
    number,
    title: truncate(pullRequest.title, 300),
    body: truncate(pullRequest.body, 4000),
    url: canonicalPullRequestUrl(repo, number),
    mergedAt: pullRequest.mergedAt ?? null,
    mergeCommit: pullRequest.mergeCommit?.oid ?? pullRequest.merge_commit_sha ?? null,
    commitShas,
    labels,
    closingIssues: uniqueIssues,
  };
}

function pullRequestsInRange({ pullRequests, compare, eventPullRequest }) {
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

export function buildReleaseInput({
  event,
  compare = {},
  pullRequests = [],
  repo,
  previousTag,
  currentSha,
  version,
  tag,
}) {
  const eventPullRequest = normalisePullRequest(repo, event?.pull_request);
  const normalisedPullRequests = pullRequests
    .map((pullRequest) => normalisePullRequest(repo, pullRequest))
    .filter(Boolean);
  const selectedPullRequests = pullRequestsInRange({
    pullRequests: normalisedPullRequests,
    compare,
    eventPullRequest,
  });
  const deduplicatedPullRequests = [
    ...new Map(selectedPullRequests.map((pullRequest) => [pullRequest.number, pullRequest])).values(),
  ].sort((left, right) => left.number - right.number);

  const commits = (compare.commits ?? []).map((commit) => ({
    sha: commit.sha,
    subject: truncate(commit.commit?.message?.split("\n", 1)[0], 300),
    url: commit.html_url ?? null,
  }));
  const files = (compare.files ?? []).slice(0, 200).map((file) => ({
    path: file.filename,
    status: file.status,
    additions: file.additions,
    deletions: file.deletions,
  }));
  const compareUrl = `https://github.com/${repo}/compare/${previousTag}...${tag}`;

  return {
    repo,
    currentSha,
    version,
    tag,
    previousTag,
    previousVersion: tagVersion(previousTag),
    compareUrl,
    pullRequests: deduplicatedPullRequests,
    commits,
    files,
  };
}

function main() {
  const options = parseArguments(process.argv.slice(2));
  const event = readJson(options.event, {});
  const compare = readJson(options.compare, {});
  const pullRequests = readJson(options.prs, []);
  const input = buildReleaseInput({
    event,
    compare,
    pullRequests,
    repo: options.repo ?? process.env.GITHUB_REPOSITORY,
    previousTag: options["previous-tag"],
    currentSha: options["current-sha"],
    version: options.version,
    tag: options.tag,
  });

  if (input.pullRequests.length === 0) {
    throw new Error("No merged pull requests were found in the release range");
  }

  const outputPath = options.output;
  if (outputPath) {
    fs.writeFileSync(outputPath, `${JSON.stringify(input, null, 2)}\n`);
  }
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
