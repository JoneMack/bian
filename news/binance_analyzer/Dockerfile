FROM ghcr.io/cirruslabs/flutter:stable

WORKDIR /app

ENV FLUTTER_SUPPRESS_ANALYTICS=true
ENV PORT=8080

COPY pubspec.yaml pubspec.lock analysis_options.yaml ./
COPY bin ./bin
COPY lib ./lib
COPY docs ./docs

RUN flutter config --no-analytics && flutter pub get

EXPOSE 8080

CMD ["dart", "run", "bin/cloud_signal_scheduler.dart"]
