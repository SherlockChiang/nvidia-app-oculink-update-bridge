import fs from "node:fs";

const config = JSON.parse(
  fs.readFileSync(
    "C:\\ProgramData\\NVIDIAAppOCuLinkDriverShim\\config.json",
    "utf8",
  ),
);
const baseUrl =
  Number(config.port) === 80
    ? `http://127.0.0.1/${config.token}/`
    : `http://127.0.0.1:${config.port}/${config.token}/`;
const controller =
  "nvidia_web_services/controller.gfeclientcontent.NG.php/";
const endpoints = {
  recommendation:
    `${controller}` +
    "com.nvidia.services.GFEClientContent_NG.getDispDrvrByDevid/",
  details:
    `${controller}` +
    "com.nvidia.services.GFEClientContent_NG.getDispDrvrDtlsByDevid/",
};

const commonPayload = {
  gcV: "11.0.8.299",
  lg: "1033",
  gLg: "en-US",
  dIDa: ["2D04_10DE_2D04_6688_1"],
  osC: "10.0.26200",
  dch: "1",
  osB: "8973",
  is6: "1",
  gIsB: "0",
  iLp: "1",
  isB: "0",
  isO: "1",
  go: "US",
  prvMd: "0",
  cSR: "0",
  IsQ: "0",
  uCst: "0",
  isCRD: "0",
};

async function request(endpoint, payload) {
  const url =
    baseUrl + endpoints[endpoint] + encodeURIComponent(JSON.stringify(payload));
  const response = await fetch(url, {
    headers: {
      accept: "application/json",
      "cache-control": "no-cache",
    },
  });
  let body;
  try {
    body = await response.json();
  } catch {
    body = null;
  }
  return { response, body };
}

const results = [];
for (const GFPV of ["610.74", "610.88"]) {
  for (const upCRD of ["0", "1"]) {
    for (const isInst of ["0", "1"]) {
      const payload = {
        ...commonPayload,
        GFPV,
        upCRD,
        isInst,
      };
      const { response, body } = await request("details", payload);
      const attributes = body?.DriverAttributes;
      results.push({
        endpoint: "details",
        requestedVersion: GFPV,
        upCRD,
        isInst,
        status: response.status,
        version: attributes?.Version,
        displayVersion: attributes?.DisplayVersion,
        release: attributes?.Release,
        name: attributes?.Name,
        releaseDateTime: attributes?.ReleaseDateTime,
        downloadVersion:
          /\/Windows\/([^/]+)\//.exec(attributes?.DownloadURL || "")?.[1],
        downloadUrl: attributes?.DownloadURL,
        clientUxKeys:
          attributes?.clientUX &&
          typeof attributes.clientUX === "object" &&
          Object.keys(attributes.clientUX),
        supported: body?.criteria?.IsSupported?.state,
        topLevelKeys: body && Object.keys(body),
      });
    }
  }
}

for (const upCRD of ["0", "1"]) {
  const payload = {
    ...commonPayload,
    GFPV: "610.74",
    upCRD,
    isInst: "1",
  };
  const { response, body } = await request("recommendation", payload);
  const attributes = body?.DriverAttributes;
  results.push({
    endpoint: "recommendation",
    requestedVersion: payload.GFPV,
    upCRD,
    isInst: payload.isInst,
    status: response.status,
    version: attributes?.Version,
    displayVersion: attributes?.DisplayVersion,
    release: attributes?.Release,
    name: attributes?.Name,
    releaseDateTime: attributes?.ReleaseDateTime,
    latestVersion:
      body?.criteria?.IsDispDriverNewer?.latestDispDriverVersion,
    downloadVersion:
      /\/Windows\/([^/]+)\//.exec(
        attributes?.DownloadURLAdmin || attributes?.DownloadURL || "",
      )?.[1],
    downloadUrl: attributes?.DownloadURLAdmin || attributes?.DownloadURL,
    clientUxKeys:
      attributes?.clientUX &&
      typeof attributes.clientUX === "object" &&
      Object.keys(attributes.clientUX),
    supported: body?.criteria?.IsSupported?.state,
    topLevelKeys: body && Object.keys(body),
  });
}

console.log(JSON.stringify(results, null, 2));
