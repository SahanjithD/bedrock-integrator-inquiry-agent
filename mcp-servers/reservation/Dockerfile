# AgentCore Runtime runs ARM64 containers and expects MCP servers on 0.0.0.0:8000/mcp.
#   docker buildx build --platform linux/arm64 -t reservation-mcp .
FROM --platform=$BUILDPLATFORM ballerina/ballerina:2201.14.0 AS build
WORKDIR /home/ballerina/src
COPY --chown=ballerina:ballerina . .
RUN bal build

FROM eclipse-temurin:25-jre
RUN groupadd --system app && useradd --system --gid app app
WORKDIR /app
COPY --from=build /home/ballerina/src/target/bin/reservation_tools.jar /app/app.jar
COPY data/ /app/data/
USER app
EXPOSE 8000
ENTRYPOINT ["java", "-jar", "/app/app.jar"]
