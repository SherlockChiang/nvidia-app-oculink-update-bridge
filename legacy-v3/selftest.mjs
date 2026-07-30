import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

const directory = path.dirname(fileURLToPath(import.meta.url));
const proxyPath = path.join(directory, "proxy.mjs");
const configPath = path.join(directory, "config.test.json");
const token =
  "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
const baseUrl = `http://127.0.0.1:17887/${token}/`;
const browserOrigin = "https://nvfile";
const expectedLatestVersion = "610.88";
const child = spawn(process.execPath, [proxyPath, configPath], {
  cwd: directory,
  stdio: ["ignore", "pipe", "pipe"],
  windowsHide: true,
});

let stderr = "";
child.stderr.on("data", (chunk) => {
  stderr += chunk.toString("utf8");
});

async function waitForHealth() {
  for (let attempt = 0; attempt < 40; attempt += 1) {
    try {
      const response = await fetch(`${baseUrl}health`);
      if (response.ok) {
        return response.json();
      }
    } catch {
      // The child process may still be binding the loopback port.
    }
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  throw new Error(`Proxy did not become healthy. ${stderr}`);
}

function metadataUrl(endpoint, payload) {
  return `${baseUrl}${endpoint}${encodeURIComponent(JSON.stringify(payload))}`;
}

function isNvidiaHttpsUrl(value) {
  const url = new URL(value);
  return (
    url.protocol === "https:" &&
    (url.hostname === "nvidia.com" || url.hostname.endsWith(".nvidia.com"))
  );
}

function headerTokens(response, name) {
  return String(response.headers.get(name) || "")
    .split(",")
    .map((value) => value.trim().toLowerCase())
    .filter(Boolean);
}

const commonPayload = {
  gcV: "11.0.8.299",
  lg: "1033",
  gLg: "en-US",
  dIDa: ["2D04_10DE_2D04_6688_1"],
  osC: "10.0.26200",
  osB: "8973",
  is6: "1",
  GFPV: "610.74",
  dch: "1",
  iLp: "1",
  isB: "0",
  gIsB: "0",
  isO: "1",
  go: "US",
  prvMd: "0",
  cSR: "0",
  IsQ: "0",
  uCst: "0",
  upCRD: "0",
  isCRD: "0",
  isInst: "1",
};

const controller =
  "nvidia_web_services/controller.gfeclientcontent.NG.php/";
const recommendationEndpoint =
  `${controller}` +
  "com.nvidia.services.GFEClientContent_NG.getDispDrvrByDevid/";
const detailsEndpoint =
  `${controller}` +
  "com.nvidia.services.GFEClientContent_NG.getDispDrvrDtlsByDevid/";

try {
  const health = await waitForHealth();
  assert.equal(health.status, "ok", "health status must be ok");
  assert.equal(health.version, 3, "the v3 proxy must be running");
  assert.equal(
    health.browserOrigin,
    browserOrigin,
    "the proxy must advertise only NVIDIA App's nvfile origin",
  );
  assert.equal(
    health.upstream,
    "https://gfwsl.geforce.com",
    "the proxy must use NVIDIA's fixed metadata upstream",
  );

  const recommendationResponse = await fetch(
    metadataUrl(recommendationEndpoint, commonPayload),
  );
  const recommendation = await recommendationResponse.json();
  const supported = String(
    recommendation?.criteria?.IsSupported?.state,
  ).toLowerCase();
  const latestVersion =
    recommendation?.criteria?.IsDispDriverNewer?.latestDispDriverVersion;
  const recommendationUrl =
    recommendation?.DriverAttributes?.DownloadURLAdmin;

  assert.equal(recommendationResponse.status, 200);
  assert.ok(["1", "true"].includes(supported));
  assert.equal(
    latestVersion,
    expectedLatestVersion,
    `NVIDIA should currently recommend ${expectedLatestVersion}`,
  );
  assert.ok(isNvidiaHttpsUrl(recommendationUrl));
  assert.ok(
    new URL(recommendationUrl).pathname.includes(
      `/Windows/${latestVersion}/`,
    ),
    "the recommendation package URL must contain the recommended version",
  );

  const detailsPayload = {
    ...commonPayload,
    GFPV: latestVersion,
    isInst: "0",
  };
  const detailsUrl = metadataUrl(detailsEndpoint, detailsPayload);
  const requestedHeaders = [
    "telemetry",
    "ot-tracer-spanid",
    "x-request-id",
  ];
  const preflightResponse = await fetch(detailsUrl, {
    method: "OPTIONS",
    headers: {
      Origin: browserOrigin,
      "Access-Control-Request-Method": "GET",
      "Access-Control-Request-Headers": requestedHeaders.join(","),
      "Access-Control-Request-Private-Network": "true",
    },
  });

  assert.equal(preflightResponse.status, 204);
  assert.equal(
    preflightResponse.headers.get("access-control-allow-origin"),
    browserOrigin,
    "CORS must allow the exact NVIDIA App origin",
  );
  assert.equal(
    preflightResponse.headers.get("access-control-allow-credentials"),
    "true",
  );
  assert.equal(
    preflightResponse.headers.get("access-control-allow-private-network"),
    "true",
  );
  assert.ok(
    headerTokens(preflightResponse, "access-control-allow-methods").includes(
      "get",
    ),
  );
  const allowedHeaders = headerTokens(
    preflightResponse,
    "access-control-allow-headers",
  );
  for (const name of requestedHeaders) {
    assert.ok(
      allowedHeaders.includes(name),
      `preflight did not allow requested header ${name}`,
    );
  }

  const detailsResponse = await fetch(detailsUrl, {
    headers: {
      Origin: browserOrigin,
      telemetry: "shim-selftest",
    },
  });
  const details = await detailsResponse.json();
  const detailsAttributes = details?.DriverAttributes;
  const detailsDownloadUrl = detailsAttributes?.DownloadURL;

  assert.equal(detailsResponse.status, 200);
  assert.equal(
    detailsResponse.headers.get("access-control-allow-origin"),
    browserOrigin,
  );
  assert.equal(
    detailsResponse.headers.get("access-control-allow-credentials"),
    "true",
  );
  assert.ok(["1", "true"].includes(
    String(details?.criteria?.IsSupported?.state).toLowerCase(),
  ));
  assert.ok(detailsAttributes?.ID, "driver details must contain an NVIDIA ID");
  assert.ok(
    detailsAttributes?.ReleaseDateTime,
    "driver details must contain a release date",
  );
  assert.ok(
    detailsAttributes?.clientUX &&
      Object.keys(detailsAttributes.clientUX).length > 0,
    "driver details must contain NVIDIA App clientUX metadata",
  );
  assert.ok(isNvidiaHttpsUrl(detailsDownloadUrl));
  assert.ok(
    new URL(detailsDownloadUrl).pathname.includes(
      `/Windows/${latestVersion}/`,
    ),
    "details must describe the version passed in GFPV",
  );

  const forbiddenOriginResponse = await fetch(detailsUrl, {
    headers: { Origin: "https://example.invalid" },
  });
  assert.equal(forbiddenOriginResponse.status, 403);
  assert.equal(
    forbiddenOriginResponse.headers.get("access-control-allow-origin"),
    null,
    "an untrusted origin must not receive an allow-origin header",
  );

  const blockedResponse = await fetch(`${baseUrl}not-allowed`);
  assert.equal(blockedResponse.status, 404);

  console.log(
    JSON.stringify(
      {
        health: health.status,
        proxyVersion: health.version,
        recommendationStatus: recommendationResponse.status,
        supported,
        latestVersion,
        recommendationHost: new URL(recommendationUrl).hostname,
        corsOrigin:
          preflightResponse.headers.get("access-control-allow-origin"),
        corsCredentials:
          preflightResponse.headers.get("access-control-allow-credentials"),
        privateNetwork:
          preflightResponse.headers.get(
            "access-control-allow-private-network",
          ),
        detailsStatus: detailsResponse.status,
        detailsId: detailsAttributes.ID,
        detailsVersionFromUrl: latestVersion,
        detailsClientUxKeys: Object.keys(detailsAttributes.clientUX),
        forbiddenOriginStatus: forbiddenOriginResponse.status,
        blockedPathStatus: blockedResponse.status,
      },
      null,
      2,
    ),
  );
} finally {
  child.kill("SIGTERM");
  await Promise.race([
    new Promise((resolve) => child.once("exit", resolve)),
    new Promise((resolve) => setTimeout(resolve, 5000)),
  ]);
}
