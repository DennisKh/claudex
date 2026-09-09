# Changelog

## [0.7.0](https://github.com/DennisKh/claudex/compare/v0.6.1...v0.7.0) (2026-09-09)


### Features

* **stream:** make usage merging, tool_uses and streamed text public ([#33](https://github.com/DennisKh/claudex/issues/33)) ([f50cd06](https://github.com/DennisKh/claudex/commit/f50cd06aca6a3bc237c65e08e4685eed679b26d0))
* **tool_runner:** gate tool calls with a before_call hook ([#32](https://github.com/DennisKh/claudex/issues/32)) ([080ad6d](https://github.com/DennisKh/claudex/commit/080ad6d130affa3e1d7d9de3d4d93d810bffdb66))
* **tool:** describe tool arguments without giving up schema inference ([#31](https://github.com/DennisKh/claudex/issues/31)) ([a44e250](https://github.com/DennisKh/claudex/commit/a44e2502ef8ec4077606c7d3359d6cc3a57e1d36))


### Bug Fixes

* **telemetry:** report the request span for streaming requests too ([#27](https://github.com/DennisKh/claudex/issues/27)) ([129b002](https://github.com/DennisKh/claudex/commit/129b0028ae99b619c5d1ed1feea5b0703044081d))
* **streaming:** cancel a stream immediately instead of at the next event ([#28](https://github.com/DennisKh/claudex/issues/28)) ([eadf02b](https://github.com/DennisKh/claudex/commit/eadf02bd730dfc0bdcac4fb0cff8bb0272317f9d))
* **tool:** return a uniform error struct from Tool.call/3 ([#29](https://github.com/DennisKh/claudex/issues/29)) ([79aa940](https://github.com/DennisKh/claudex/commit/79aa940b597a2b72f1d3563c96630f43c76c8b59))

## [0.6.1](https://github.com/DennisKh/claudex/compare/v0.6.0...v0.6.1) (2026-09-07)


### Build System

* add Hex package metadata, ex_doc and an MIT licence ([#20](https://github.com/DennisKh/claudex/issues/20)) ([89a2712](https://github.com/DennisKh/claudex/commit/89a2712e2c78f7f5903063f3ce67b1b69c033b9c))

## [0.6.0](https://github.com/DennisKh/claudex/compare/v0.5.0...v0.6.0) (2026-09-07)


### Features

* **batches:** add the Message Batches API ([#18](https://github.com/DennisKh/claudex/issues/18)) ([c0a2710](https://github.com/DennisKh/claudex/commit/c0a27104dbdae4052e3df63a5e618ad418a33f50))
* **files:** add the Files API ([#17](https://github.com/DennisKh/claudex/issues/17)) ([e5b738a](https://github.com/DennisKh/claudex/commit/e5b738a6c4c12db18a5ed82a62dcbe5d9f9da789))

## [0.5.0](https://github.com/DennisKh/claudex/compare/v0.4.0...v0.5.0) (2026-09-07)


### Features

* **telemetry:** document the events and ship a default logger ([cbed35a](https://github.com/DennisKh/claudex/commit/cbed35ab03749cbee00ad4a8360190dd7aa0bcf2))
* **telemetry:** document the events and ship a default logger ([c16f67c](https://github.com/DennisKh/claudex/commit/c16f67cd0e9fce913a53755ea1884023374c5e1c))

## [0.4.0](https://github.com/DennisKh/claudex/compare/v0.3.0...v0.4.0) (2026-09-07)


### Features

* **models:** add the Models API with shared pagination ([bb0a231](https://github.com/DennisKh/claudex/commit/bb0a231063c1194d51ad777b6b4e053f34bf1cc3))
* **models:** add the Models API with shared pagination ([d29b551](https://github.com/DennisKh/claudex/commit/d29b551e04c46da49ae810f1ba9cb6b2521507cf))

## [0.3.0](https://github.com/DennisKh/claudex/compare/v0.2.0...v0.3.0) (2026-09-07)


### Features

* **tool_runner:** add the agentic loop over registered tools ([d416912](https://github.com/DennisKh/claudex/commit/d4169128f4114bc1aec7ed72b2cf371992ca07df))
* **tool_runner:** add the agentic loop over registered tools ([f72a1e2](https://github.com/DennisKh/claudex/commit/f72a1e26372e480933194a4c1df9e9063a635df4))

## [0.2.0](https://github.com/DennisKh/claudex/compare/v0.1.1...v0.2.0) (2026-09-07)


### Features

* **messages:** add the Messages API with streaming and tool schemas ([7fb59f8](https://github.com/DennisKh/claudex/commit/7fb59f86f54e0b89144c3c521d77e0b84ccff805))


### Bug Fixes

* **ci:** let a feat bump the minor version again ([d298d07](https://github.com/DennisKh/claudex/commit/d298d07c7ab4739f1ec05c315dd315946356d2ee))
* **ci:** let a feat bump the minor version again ([a981e87](https://github.com/DennisKh/claudex/commit/a981e87aef9040b69473416ff301e93c9a4b1364))

## [0.1.1](https://github.com/DennisKh/claudex/compare/v0.1.0...v0.1.1) (2026-09-06)


### Features

* add the base client, request layer and error handling ([3ee95c1](https://github.com/DennisKh/claudex/commit/3ee95c14a45ee0ef9e2a910adf7bef1296577be8))
* add the base client, request layer and error handling ([d8c9686](https://github.com/DennisKh/claudex/commit/d8c9686cee1f00fdf888caaf42c332f0fb6a8804))


### Bug Fixes

* **ci:** anchor release-please at 0.1.0 so the next release is 0.2.0 ([5bc6c58](https://github.com/DennisKh/claudex/commit/5bc6c580ac1411f2d3c2d363975b284a6125275c))
