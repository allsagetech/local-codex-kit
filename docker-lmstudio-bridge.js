const http = require("http");

const listenHost = process.env.LOCAL_CODEX_BRIDGE_HOST || "127.0.0.1";
const listenPort = Number(process.env.LOCAL_CODEX_BRIDGE_PORT || "1234");
const targetHost = process.env.LOCAL_CODEX_LMSTUDIO_HOST || "host.docker.internal";
const targetPort = Number(process.env.LOCAL_CODEX_LMSTUDIO_PORT || "1234");

http.createServer((req, res) => {
  const proxyReq = http.request({
    hostname: targetHost,
    port: targetPort,
    path: req.url,
    method: req.method,
    headers: { ...req.headers, host: `${targetHost}:${targetPort}` }
  }, (proxyRes) => {
    res.writeHead(proxyRes.statusCode || 502, proxyRes.headers);
    proxyRes.pipe(res);
  });

  proxyReq.on("error", (err) => {
    res.writeHead(502);
    res.end(err.message);
  });

  req.pipe(proxyReq);
}).listen(listenPort, listenHost, () => {
  console.log(`LM Studio bridge listening on http://${listenHost}:${listenPort} -> http://${targetHost}:${targetPort}`);
});
