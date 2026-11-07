# The ECS task definition uses ARM64 (Graviton) Fargate tasks. Build with:
#   docker buildx build --platform linux/arm64 -t inquiry-listener .
#
# The build stage runs on the build machine's own platform (the JAR is platform independent).
# TODO(verify): image tags for Ballerina 2201.14.0 and the Java runtime it targets (Java 25).
FROM --platform=$BUILDPLATFORM ballerina/ballerina:2201.14.0 AS build
WORKDIR /home/ballerina/src
COPY --chown=ballerina:ballerina . .
RUN bal build

FROM eclipse-temurin:25-jre
RUN groupadd --system app && useradd --system --gid app app
WORKDIR /app
COPY --from=build /home/ballerina/src/target/bin/inquiry_listener.jar /app/app.jar
USER app
# No ports: the listener only polls SQS and calls AWS services.
ENTRYPOINT ["java", "-jar", "/app/app.jar"]
