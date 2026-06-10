import { createServer } from "node:http";

const port = Number.parseInt(process.env.PORT ?? "3000", 10);
const version = process.env.SERVICE_VERSION ?? "0.1.0";

let requestsTotal = 0;

const server = createServer((request, response) => {
  requestsTotal += 1;

  if (request.url === "/health") {
    response.writeHead(200, { "content-type": "application/json" });
    response.end(JSON.stringify({ ok: true }));
    return;
  }

  if (request.url === "/version") {
    response.writeHead(200, { "content-type": "application/json" });
    response.end(JSON.stringify({ version }));
    return;
  }

  if (request.url === "/metrics") {
    response.writeHead(200, { "content-type": "text/plain; version=0.0.4" });
    response.end(
      [
        "# HELP node_service_requests_total Total HTTP requests handled.",
        "# TYPE node_service_requests_total counter",
        `node_service_requests_total ${requestsTotal}`,
        "# HELP node_service_uptime_seconds Process uptime in seconds.",
        "# TYPE node_service_uptime_seconds gauge",
        `node_service_uptime_seconds ${process.uptime()}`,
        "",
      ].join("\n"),
    );
    return;
  }

  response.writeHead(200, { "content-type": "application/json" });
  response.end(JSON.stringify({ service: "node-service-demo" }));
});

server.listen(port, "127.0.0.1", () => {
  console.log(`node-service-demo listening on ${port}`);
});
