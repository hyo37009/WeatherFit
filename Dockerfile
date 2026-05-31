# syntax=docker/dockerfile:1

### Build stage ###
FROM amazoncorretto:21-alpine AS builder
WORKDIR /app

# 1) 빌드 스크립트/래퍼만 먼저 복사 → 의존성 레이어 캐싱
#    소스가 바뀌어도 build.gradle이 그대로면 이 레이어는 재사용된다.
COPY gradlew settings.gradle build.gradle ./
COPY gradle ./gradle
RUN chmod +x ./gradlew && ./gradlew dependencies --no-daemon

# 2) 소스 복사 후 실행 가능한 부트 jar 빌드
COPY src ./src
RUN ./gradlew clean bootJar --no-daemon -x test

# 3) Spring Boot layered jar 추출 (의존성 / 로더 / 스냅샷 / 앱 분리)
RUN java -Djarmode=layertools -jar build/libs/*.jar extract --destination extracted

### Runtime stage ###
FROM amazoncorretto:21-alpine
ENV SPRING_PROFILES_ACTIVE=docker \
    TZ=Asia/Seoul
RUN apk add --no-cache curl tzdata && \
    addgroup -S spring && adduser -S -G spring spring
WORKDIR /app

# 변경 빈도가 낮은 레이어부터 복사 → 캐시 적중률 극대화
COPY --from=builder --chown=spring:spring /app/extracted/dependencies/ ./
COPY --from=builder --chown=spring:spring /app/extracted/spring-boot-loader/ ./
COPY --from=builder --chown=spring:spring /app/extracted/snapshot-dependencies/ ./
COPY --from=builder --chown=spring:spring /app/extracted/application/ ./

# logback-spring.xml이 ./logs에 파일 로그를 남기므로 디렉토리 생성 + 소유권 부여 (non-root 실행 대비)
RUN mkdir -p logs && chown spring:spring /app logs

USER spring
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=40s --retries=3 \
    CMD curl -f http://localhost:8080/actuator/health || exit 1
ENTRYPOINT ["sh", "-c", "exec java $JVM_OPTS org.springframework.boot.loader.launch.JarLauncher"]
