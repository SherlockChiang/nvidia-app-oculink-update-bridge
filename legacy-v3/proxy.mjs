import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const configPath = process.argv[2] || path.join(scriptDirectory, "config.json");
const config = JSON.parse(fs.readFileSync(configPath, "utf8"));

const port = Number(config.port);
const token = String(config.token || "");
const upstreamOrigin = "https://gfwsl.geforce.com";
const runtimeDirectory = path.resolve(String(config.runtimeDirectory || ""));
const logPath = path.join(runtimeDirectory, "shim.log");
const pidPath = path.join(runtimeDirectory, "shim.pid");
const allowedMethods = new Set(["GET", "HEAD", "POST", "OPTIONS"]);
const allowedBrowserOrigin = "https://nvfile";
const metadataControllerPrefixes = [
  "/nvidia_web_services/controller.gfeclientcontent.NG.php/",
  "/nvidia_web_services/controller.driverinstallercontent.NG.php/",
  "/nvidia_web_services/controller.gfeclientaffinity.php/",
  "/nvidia_web_services/controller.gfeclientvrs.php/",
];
const driverEndpoints = new Map([
  [
    "/nvidia_web_services/controller.gfeclientcontent.NG.php/com.nvidia.services.GFEClientContent_NG.getDispDrvrByDevid/",
    "driver-recommendation",
  ],
  [
    "/nvidia_web_services/controller.gfeclientcontent.NG.php/com.nvidia.services.GFEClientContent_NG.getDispDrvrDtlsByDevid/",
    "driver-details",
  ],
]);
const maximumPayloadLength = 128 * 1024;
const maximumRequestBodyLength = 256 * 1024;
const maximumResponseLength = 8 * 1024 * 1024;

if (
  !Number.isInteger(port) ||
  (port !== 80 && (port < 1024 || port > 65535))
) {
  throw new Error(
    "config.port must be 80 or an integer between 1024 and 65535",
  );
}
if (!/^[a-f0-9]{32,128}$/i.test(token)) {
  throw new Error("config.token must be a random hexadecimal string");
}
if (!path.isAbsolute(runtimeDirectory)) {
  throw new Error("config.runtimeDirectory must be an absolute path");
}
fs.mkdirSync(runtimeDirectory, { recursive: true });

function log(event, fields = {}) {
  try {
    if (fs.existsSync(logPath) && fs.statSync(logPath).size > 5 * 1024 * 1024) {
      fs.rmSync(`${logPath}.1`, { force: true });
      fs.renameSync(logPath, `${logPath}.1`);
    }
    fs.appendFileSync(
      logPath,
      `${JSON.stringify({ time: new Date().toISOString(), event, ...fields })}\n`,
      "utf8",
    );
  } catch {
    // Logging must never break NVIDIA App update discovery.
  }
}

function corsResponseHeaders(request, { preflight = false } = {}) {
  if (request.headers.origin !== allowedBrowserOrigin) {
    return {};
  }

  const headers = {
    "access-control-allow-origin": allowedBrowserOrigin,
    "access-control-allow-credentials": "true",
    vary: preflight
      ? "Origin, Access-Control-Request-Method, Access-Control-Request-Headers, Access-Control-Request-Private-Network"
      : "Origin",
  };
  if (preflight) {
    headers["access-control-allow-methods"] = "GET, HEAD, POST, OPTIONS";
    headers["access-control-max-age"] = "600";
    const requestedHeaders = String(
      request.headers["access-control-request-headers"] || "",
    ).trim();
    if (requestedHeaders) {
      headers["access-control-allow-headers"] = requestedHeaders;
    }
    if (
      String(
        request.headers["access-control-request-private-network"] || "",
      ).toLowerCase() === "true"
    ) {
      headers["access-control-allow-private-network"] = "true";
    }
  } else {
    headers["access-control-expose-headers"] = "ETag, X-Request-ID";
  }
  return headers;
}

function jsonResponse(request, response, statusCode, value) {
  const body = Buffer.from(JSON.stringify(value), "utf8");
  response.writeHead(statusCode, {
    "content-type": "application/json; charset=utf-8",
    "content-length": String(body.length),
    "cache-control": "no-store",
    ...corsResponseHeaders(request),
  });
  response.end(body);
}

function sameTypeZero(value) {
  return typeof value === "number" ? 0 : "0";
}

function rewriteDriverRequest(rawPath) {
  const endpoint = [...driverEndpoints.keys()].find((candidate) =>
    rawPath.startsWith(candidate),
  );
  if (!endpoint) {
    return {
      rawPath,
      changed: false,
      route: "metadata-pass-through",
    };
  }

  const encodedPayload = rawPath.slice(endpoint.length);
  if (!encodedPayload || encodedPayload.includes("/")) {
    throw new Error("Unexpected NVIDIA driver metadata path");
  }
  if (encodedPayload.length > maximumPayloadLength) {
    throw new Error("NVIDIA driver metadata payload is too large");
  }

  const payload = JSON.parse(decodeURIComponent(encodedPayload));
  if (
    payload === null ||
    typeof payload !== "object" ||
    Array.isArray(payload) ||
    !Array.isArray(payload.dIDa) ||
    payload.dIDa.length < 1 ||
    payload.dIDa.length > 32 ||
    !payload.dIDa.every(
      (deviceId) => typeof deviceId === "string" && deviceId.length <= 256,
    )
  ) {
    throw new Error("Unexpected NVIDIA driver metadata payload");
  }
  const before = {
    iLp: payload.iLp,
    osC: payload.osC,
    osB: payload.osB,
  };

  payload.iLp = sameTypeZero(payload.iLp);

  const osCode = String(payload.osC || "");
  const osParts = osCode.split(".");
  if (osParts.length >= 2 && osParts[0] === "10" && osParts[1] === "0") {
    payload.osC = "10.0";
    if (osParts.length >= 3) {
      payload.osB = osParts[2];
    }
  }

  const after = {
    iLp: payload.iLp,
    osC: payload.osC,
    osB: payload.osB,
  };

  return {
    rawPath: `${endpoint}${encodeURIComponent(JSON.stringify(payload))}`,
    changed: JSON.stringify(before) !== JSON.stringify(after),
    route: driverEndpoints.get(endpoint),
    before,
    after,
    deviceIds: Array.isArray(payload.dIDa) ? payload.dIDa : [],
    requestedVersion: payload.GFPV,
  };
}

function isPermittedMetadataPath(rawPath) {
  if (
    rawPath.length > maximumPayloadLength ||
    rawPath.includes("\\") ||
    rawPath.includes("\0") ||
    /%2f|%5c/i.test(rawPath) ||
    rawPath.split("/").includes("..")
  ) {
    return false;
  }
  return metadataControllerPrefixes.some((prefix) => rawPath.startsWith(prefix));
}

function copyRequestHeaders(request) {
  const headers = {};
  for (const name of [
    "accept",
    "accept-language",
    "cache-control",
    "content-type",
    "cookie",
    "authorization",
    "user-agent",
    "telemetry",
    "ot-tracer-sampled",
    "ot-tracer-spanid",
    "ot-tracer-traceid",
    "traceparent",
    "tracestate",
    "baggage",
    "x-request-id",
  ]) {
    const value = request.headers[name];
    if (value !== undefined) {
      headers[name] = value;
    }
  }
  headers.host = "gfwsl.geforce.com";
  return headers;
}

async function readRequestBody(request) {
  if (!["POST"].includes(request.method || "")) {
    return undefined;
  }

  const declaredLength = Number(request.headers["content-length"]);
  if (
    Number.isFinite(declaredLength) &&
    declaredLength > maximumRequestBodyLength
  ) {
    throw new Error("NVIDIA metadata request body is too large");
  }

  const chunks = [];
  let receivedLength = 0;
  for await (const chunk of request) {
    receivedLength += chunk.length;
    if (receivedLength > maximumRequestBodyLength) {
      throw new Error("NVIDIA metadata request body exceeded the size limit");
    }
    chunks.push(Buffer.from(chunk));
  }
  return Buffer.concat(chunks);
}

async function relayMetadata(request, response, rewrittenPath, rawQuery) {
  const upstreamUrl = `${upstreamOrigin}${rewrittenPath}${rawQuery}`;
  const requestBody = await readRequestBody(request);
  const upstreamResponse = await fetch(upstreamUrl, {
    method: request.method,
    headers: copyRequestHeaders(request),
    body: requestBody,
    redirect: "error",
    cache: "no-store",
    signal: AbortSignal.timeout(30000),
  });

  const declaredLength = Number(upstreamResponse.headers.get("content-length"));
  if (
    Number.isFinite(declaredLength) &&
    declaredLength > maximumResponseLength
  ) {
    throw new Error("NVIDIA metadata response is too large");
  }

  const chunks = [];
  let receivedLength = 0;
  if (request.method !== "HEAD" && upstreamResponse.body) {
    for await (const chunk of upstreamResponse.body) {
      receivedLength += chunk.length;
      if (receivedLength > maximumResponseLength) {
        throw new Error("NVIDIA metadata response exceeded the size limit");
      }
      chunks.push(Buffer.from(chunk));
    }
  }
  const body = Buffer.concat(chunks);

  const responseHeaders = {
    "content-type":
      upstreamResponse.headers.get("content-type") || "application/json",
    "content-length": String(body.length),
    "cache-control": "no-store",
    ...corsResponseHeaders(request),
  };
  for (const name of ["etag", "x-request-id"]) {
    const value = upstreamResponse.headers.get(name);
    if (value) {
      responseHeaders[name] = value;
    }
  }

  response.writeHead(upstreamResponse.status, responseHeaders);
  response.end(body);
  return { status: upstreamResponse.status, body };
}

const server = http.createServer(async (request, response) => {
  const startedAt = Date.now();
  try {
    if (!allowedMethods.has(request.method || "")) {
      response.setHeader("allow", "GET, HEAD, POST, OPTIONS");
      return jsonResponse(request, response, 405, {
        error: "Method not allowed",
      });
    }

    const requestUrl = new URL(request.url || "/", `http://127.0.0.1:${port}`);
    const requiredPrefix = `/${token}/`;
    if (!requestUrl.pathname.startsWith(requiredPrefix)) {
      return jsonResponse(request, response, 404, { error: "Not found" });
    }

    const relativeRawTarget = (request.url || "/").slice(requiredPrefix.length);
    const queryIndex = relativeRawTarget.indexOf("?");
    const rawPath =
      "/" +
      (queryIndex >= 0
        ? relativeRawTarget.slice(0, queryIndex)
        : relativeRawTarget);
    const rawQuery =
      queryIndex >= 0 ? relativeRawTarget.slice(queryIndex) : "";

    if (rawPath === "/health") {
      return jsonResponse(request, response, 200, {
        status: "ok",
        version: 3,
        port,
        upstream: upstreamOrigin,
        pid: process.pid,
        browserOrigin: allowedBrowserOrigin,
      });
    }

    if (!isPermittedMetadataPath(rawPath)) {
      return jsonResponse(request, response, 404, {
        error: "Only NVIDIA metadata controller endpoints are permitted",
      });
    }

    const origin = request.headers.origin;
    if (origin !== undefined && origin !== allowedBrowserOrigin) {
      return jsonResponse(request, response, 403, {
        error: "Browser origin is not permitted",
      });
    }

    if (request.method === "OPTIONS") {
      const requestedMethod = String(
        request.headers["access-control-request-method"] || "",
      ).toUpperCase();
      if (
        origin !== allowedBrowserOrigin ||
        !["GET", "HEAD", "POST"].includes(requestedMethod)
      ) {
        return jsonResponse(request, response, 403, {
          error: "CORS preflight is not permitted",
        });
      }
      response.writeHead(204, {
        "content-length": "0",
        "cache-control": "no-store",
        ...corsResponseHeaders(request, { preflight: true }),
      });
      response.end();
      log("cors-preflight", {
        status: 204,
        durationMs: Date.now() - startedAt,
        requestedMethod,
        requestedHeaders:
          request.headers["access-control-request-headers"] || "",
        privateNetwork:
          request.headers["access-control-request-private-network"] || "",
      });
      return;
    }

    const rewrite = rewriteDriverRequest(rawPath);

    const upstream = await relayMetadata(
      request,
      response,
      rewrite.rawPath,
      rawQuery,
    );

    let version;
    try {
      const parsed = JSON.parse(upstream.body.toString("utf8"));
      version =
        parsed?.DriverAttributes?.Version ??
        parsed?.DriverAttributes?.DisplayVersion ??
        parsed?.criteria?.IsDispDriverNewer?.latestDispDriverVersion;
    } catch {
      version = undefined;
    }

    log("metadata-relay", {
      status: upstream.status,
      durationMs: Date.now() - startedAt,
      method: request.method,
      route: rewrite.route,
      browserOrigin: origin,
      changed: rewrite.changed,
      before: rewrite.before,
      after: rewrite.after,
      deviceIds: rewrite.deviceIds,
      requestedVersion: rewrite.requestedVersion,
      returnedVersion: version,
    });
  } catch (error) {
    log("request-error", {
      durationMs: Date.now() - startedAt,
      message: String(error?.stack || error),
    });
    if (!response.headersSent) {
      jsonResponse(request, response, 502, {
        error: "NVIDIA metadata relay failed",
        detail: String(error?.message || error),
      });
    } else {
      response.destroy();
    }
  }
});

server.on("error", (error) => {
  log("server-error", { message: String(error?.stack || error) });
  process.exitCode = 1;
});

server.listen(port, "127.0.0.1", () => {
  fs.writeFileSync(pidPath, String(process.pid), "utf8");
  log("server-start", { port, pid: process.pid });
});

function shutdown(signal) {
  log("server-stop", { signal });
  server.close(() => {
    fs.rmSync(pidPath, { force: true });
    process.exit(0);
  });
  setTimeout(() => process.exit(0), 3000).unref();
}

process.on("SIGINT", () => shutdown("SIGINT"));
process.on("SIGTERM", () => shutdown("SIGTERM"));
