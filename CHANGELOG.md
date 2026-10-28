# Changelog

## [0.11.0](https://github.com/DennisKh/claudex/compare/v0.10.0...v0.11.0) (2026-10-28)


### ⚠ BREAKING CHANGES

* **client:** requests now use API version 2026-10-21, which answers `temperature`, `top_p` or `top_k`, a `document` block directly in an `assistant` message, and a `text` block with `citations` in a `user` message with a 400. `Claudex.Client.put_header(client, "anthropic-version", "2023-06-01")` sends the previous version.
* **tool_runner:** a `{:turn, turn}` handler for `stream_to/3` can now receive a turn with `stop: :cancelled`, and a finished turn can be followed by `:cancelled` instead of `:done`.
* **tool_runner:** `ToolRunner.stream_to/3` used to ignore `every:`; it now batches events, so a reader that matches only `{:event, event}` must also handle `{:events, events}`, and an `:every` that is not a positive integer raises `ArgumentError`.
* **tool_runner:** add stream!/3 and deprecate stream/3 ([#127](https://github.com/DennisKh/claudex/issues/127))
* **tool_runner:** report a cancelled reply as cancelled ([#125](https://github.com/DennisKh/claudex/issues/125))
* **messages:** refuse string-keyed params and send struct system blocks ([#118](https://github.com/DennisKh/claudex/issues/118))
* **tool:** name a pattern parameter for the variable bound to it ([#111](https://github.com/DennisKh/claudex/issues/111))
* **tool:** refuse @tool on a function whose name the API rejects ([#110](https://github.com/DennisKh/claudex/issues/110))
* **tool:** refuse two @tool functions that would share a name ([#108](https://github.com/DennisKh/claudex/issues/108))
* **tracing:** report provider and token counts the way the GenAI conventions define them ([#106](https://github.com/DennisKh/claudex/issues/106))
* **message:** map the compaction stop reason and resume it in the tool runner ([#104](https://github.com/DennisKh/claudex/issues/104))
* **telemetry:** a streamed 4xx/5xx moves from `:exception` to `:stop`, and a plain request that got no response moves from `:stop` with `status: nil` to `:exception`.

### Features

* **client:** add headers and betas to a copy of a client ([#114](https://github.com/DennisKh/claudex/issues/114)) ([a2672c4](https://github.com/DennisKh/claudex/commit/a2672c470723ff189c3b0053ea53f457fa12311a))
* **models:** decode a model's lifecycle, line and retirement dates ([#119](https://github.com/DennisKh/claudex/issues/119)) ([92c1b8f](https://github.com/DennisKh/claudex/commit/92c1b8f00bfbc1c59b7b7bdb67e94469e7d5de0d))
* **schema:** build a struct's JSON schema while it compiles with use Claudex.Schema ([#95](https://github.com/DennisKh/claudex/issues/95)) ([9d059eb](https://github.com/DennisKh/claudex/commit/9d059ebfd68b8888054634f3e095b6fca3aaf4bc))
* send :every batches on a timer and add ContentBlock.replayable?/1 ([#88](https://github.com/DennisKh/claudex/issues/88)) ([164eb30](https://github.com/DennisKh/claudex/commit/164eb30dc940ff5d97b14b0ea222cd1e41df4733))
* **streaming:** batch stream_to/3 events over a window ([#78](https://github.com/DennisKh/claudex/issues/78)) ([417bdf7](https://github.com/DennisKh/claudex/commit/417bdf78e3cccbe716add8cea9f5d1d185196049))
* **tool_runner:** add stream!/3 and deprecate stream/3 ([#127](https://github.com/DennisKh/claudex/issues/127)) ([116cbd3](https://github.com/DennisKh/claudex/commit/116cbd3df212013c325e34e9815bf045392031f0))
* **tool_runner:** batch stream_to/3 events with :every ([#130](https://github.com/DennisKh/claudex/issues/130)) ([a0421db](https://github.com/DennisKh/claudex/commit/a0421db94c19ce5142c39d132efa5b07d8873beb))
* **tool_runner:** halt a run and resume it from its own history ([#82](https://github.com/DennisKh/claudex/issues/82)) ([26c1c22](https://github.com/DennisKh/claudex/commit/26c1c228521d8f8a8658961b81aacec36ba5bb0c))
* **tool_runner:** send the turn a cancel ended from stream_to/3 ([#131](https://github.com/DennisKh/claudex/issues/131)) ([02d949b](https://github.com/DennisKh/claudex/commit/02d949b3cf51a627aa4591bb5de954950745a3c8))
* **tool:** let a tool return content blocks ([#122](https://github.com/DennisKh/claudex/issues/122)) ([c861dc2](https://github.com/DennisKh/claudex/commit/c861dc254530411e45442743411009d9e93f8128))
* **tool:** set the API's tool-definition fields from [@tool](https://github.com/tool) ([#113](https://github.com/DennisKh/claudex/issues/113)) ([5f112ef](https://github.com/DennisKh/claudex/commit/5f112ef6b0ee55752a60120654872498ff1abb09))
* **tracing:** run a conversation in a block ([#81](https://github.com/DennisKh/claudex/issues/81)) ([cc4c030](https://github.com/DennisKh/claudex/commit/cc4c030424329af806ad06a6c50482144c90cc8c))
* **usage:** answer whether prompt caching did anything ([#83](https://github.com/DennisKh/claudex/issues/83)) ([6dcd640](https://github.com/DennisKh/claudex/commit/6dcd640b30f73dfa9fabd924b5802fa2087ba5a3))


### Bug Fixes

* 0.11.0 review findings ([#87](https://github.com/DennisKh/claudex/issues/87)) ([708e442](https://github.com/DennisKh/claudex/commit/708e442d817b5b5ed26b9d0dbe71fdf7f955453f))
* **batches:** prepare each request's params the way Messages.create/2 does ([#96](https://github.com/DennisKh/claudex/issues/96)) ([03b5812](https://github.com/DennisKh/claudex/commit/03b581271db6da939ed5670aa1123655d0042ba3))
* **client:** keep the API key out of the Req request a client holds ([#120](https://github.com/DennisKh/claudex/issues/120)) ([7daabff](https://github.com/DennisKh/claudex/commit/7daabff1c372ee02dc65412ee65e83b20f83fd2e))
* **client:** retry failed requests the way the official SDKs do ([#99](https://github.com/DennisKh/claudex/issues/99)) ([f0935cd](https://github.com/DennisKh/claudex/commit/f0935cdf9aaac0a98964ad8f6100b48828544432))
* **client:** send API version 2026-10-21 ([#133](https://github.com/DennisKh/claudex/issues/133)) ([1149852](https://github.com/DennisKh/claudex/commit/114985221a5af4ecdf7d46c0a834fdf5755d44ef))
* **deps:** bump req from 0.7.4 to 0.7.5 ([#97](https://github.com/DennisKh/claudex/issues/97)) ([cad56f5](https://github.com/DennisKh/claudex/commit/cad56f5f7f05dfefc4a2a78d5818a9c3b62835fe))
* **gen.tracing:** leave the service name out at an umbrella root ([#128](https://github.com/DennisKh/claudex/issues/128)) ([21e9b90](https://github.com/DennisKh/claudex/commit/21e9b90e2fffb8a213ea8736fc8082fe1fad980c))
* **message:** leave a cut-off reply's unanswered tool calls out of the history ([#91](https://github.com/DennisKh/claudex/issues/91)) ([5154bfe](https://github.com/DennisKh/claudex/commit/5154bfe4ebc92be2bceee93839bc91e2d1901d83))
* **message:** leave a cut-off stream's unsendable blocks out of the history ([#86](https://github.com/DennisKh/claudex/issues/86)) ([88974a8](https://github.com/DennisKh/claudex/commit/88974a85c86bfd68075eda3b23db9cd2e484f0aa))
* **message:** map the compaction stop reason and resume it in the tool runner ([#104](https://github.com/DennisKh/claudex/issues/104)) ([d436c26](https://github.com/DennisKh/claudex/commit/d436c26c7c5911a1ef0441f1023f2066c521582f))
* **messages:** refuse a non-streaming request that can outlast the default timeout ([#98](https://github.com/DennisKh/claudex/issues/98)) ([d055eb2](https://github.com/DennisKh/claudex/commit/d055eb2d981b81e59dddb1ba94717644c664389f))
* **messages:** refuse string-keyed params and send struct system blocks ([#118](https://github.com/DennisKh/claudex/issues/118)) ([d5eb71f](https://github.com/DennisKh/claudex/commit/d5eb71ff5812d631a81ac7e92c95849b93020871))
* **models:** send the lifecycle filter as the list the API reads ([#115](https://github.com/DennisKh/claudex/issues/115)) ([5a6a478](https://github.com/DennisKh/claudex/commit/5a6a4785a41f1af35a86c3e96ae8a00ce469771b))
* **page:** walk back with before_id instead of sending both cursors ([#107](https://github.com/DennisKh/claudex/issues/107)) ([8906a0e](https://github.com/DennisKh/claudex/commit/8906a0e4b588b8ae6888f2ed1dd1b5a4970e6fa8))
* **schema:** recompile a module whose schema came from a struct that changed ([#129](https://github.com/DennisKh/claudex/issues/129)) ([c4fbd8a](https://github.com/DennisKh/claudex/commit/c4fbd8a4b2eff961a5a91eeb9f305cf8db1e5212))
* **streaming:** keep the content a message_start event carries ([bf08e91](https://github.com/DennisKh/claudex/commit/bf08e916426382b0f477e0d87a134e79c0b7a280))
* **streaming:** keep the summary a compaction delta carries ([#90](https://github.com/DennisKh/claudex/issues/90)) ([0b21499](https://github.com/DennisKh/claudex/commit/0b21499284105759a8f66062c5c73c16e2595397))
* **stream:** keep iterations, context edits and raw fields from message_delta ([#105](https://github.com/DennisKh/claudex/issues/105)) ([132a372](https://github.com/DennisKh/claudex/commit/132a37280a42c2ec460350c68ff8fb0cf167d96e))
* **stream:** leave nothing in the caller's mailbox when a stream stops early ([#102](https://github.com/DennisKh/claudex/issues/102)) ([3b8698d](https://github.com/DennisKh/claudex/commit/3b8698de53be1e357c2c3bcb1cae4a8549d30951))
* **stream:** stop a forwarded stream when its caller exits normally ([#100](https://github.com/DennisKh/claudex/issues/100)) ([0dd2955](https://github.com/DennisKh/claudex/commit/0dd295597a7cb3db3aec86343ef32697b8eaeb7c))
* **stream:** stop a request the moment the process it serves dies ([#121](https://github.com/DennisKh/claudex/issues/121)) ([1a11c4a](https://github.com/DennisKh/claudex/commit/1a11c4a46fb910fbedc57fcb7b46e83aa0ab1a6f))
* **telemetry:** report a failed request the same way on both transports ([#103](https://github.com/DennisKh/claudex/issues/103)) ([4a2ca30](https://github.com/DennisKh/claudex/commit/4a2ca304a177f68636aeb735b4e217b1d78dbaa0))
* **telemetry:** report a streamed request's tokens and say what Claudex logs ([#116](https://github.com/DennisKh/claudex/issues/116)) ([04c8662](https://github.com/DennisKh/claudex/commit/04c86627f0030d4cb57f15f5c7c7578772b702f2))
* **tool_runner:** answer a call whose streamed input doesn't parse instead of running it ([#124](https://github.com/DennisKh/claudex/issues/124)) ([cce44c1](https://github.com/DennisKh/claudex/commit/cce44c1f6bf421f58bccf172653e117d4cbb2262))
* **tool_runner:** encode tool results with Jason so a struct sends only the fields it exposes ([#92](https://github.com/DennisKh/claudex/issues/92)) ([f1a8f39](https://github.com/DennisKh/claudex/commit/f1a8f395152af05e0723615a67fc3e9e844b98b3))
* **tool_runner:** end on the finished turn when a cancel arrives between turns ([#101](https://github.com/DennisKh/claudex/issues/101)) ([4dc2096](https://github.com/DennisKh/claudex/commit/4dc209631d2fea7d70be8fc8c0cf6af8fc871269))
* **tool_runner:** keep an unfinished reply's calls out of the history ([#84](https://github.com/DennisKh/claudex/issues/84)) ([e70a6e7](https://github.com/DennisKh/claudex/commit/e70a6e770a09d4cce1589bca9ab277cbfecfde72))
* **tool_runner:** report a cancelled reply as cancelled ([#125](https://github.com/DennisKh/claudex/issues/125)) ([cf70457](https://github.com/DennisKh/claudex/commit/cf704574b5943c4425050c9ef4ff38eaa05cfe01))
* **tool_runner:** stop instead of running calls under an unknown stop reason ([#85](https://github.com/DennisKh/claudex/issues/85)) ([c6ffb8d](https://github.com/DennisKh/claudex/commit/c6ffb8d9fd531c6f25adcdf7e7f992fe019693e5))
* **tool:** fit a strict tool's inferred schema to the subset strict mode takes ([#94](https://github.com/DennisKh/claudex/issues/94)) ([a73c46e](https://github.com/DennisKh/claudex/commit/a73c46e11767d1ab9a854f4ad9cb1e9f99fc7d9e))
* **tool:** name a pattern parameter for the variable bound to it ([#111](https://github.com/DennisKh/claudex/issues/111)) ([907b1b3](https://github.com/DennisKh/claudex/commit/907b1b3b88bdd3171887d0f94987a4364b3bbba9))
* **tool:** refuse [@tool](https://github.com/tool) on a function whose name the API rejects ([#110](https://github.com/DennisKh/claudex/issues/110)) ([ff351dc](https://github.com/DennisKh/claudex/commit/ff351dc72149180d352dd070d398530352ee1f70))
* **tool:** refuse two [@tool](https://github.com/tool) functions that would share a name ([#108](https://github.com/DennisKh/claudex/issues/108)) ([fc195a4](https://github.com/DennisKh/claudex/commit/fc195a48212467dbbce05222e9f55201532ff348))
* **tool:** send a tool call's caller and toolset back, and keep the runner in its container ([#89](https://github.com/DennisKh/claudex/issues/89)) ([a951ea7](https://github.com/DennisKh/claudex/commit/a951ea7c3e456353f79ed3c8ccf32defa1dd8170))
* **tracing:** keep a failure's message and arguments off spans unless trace_content is on ([#93](https://github.com/DennisKh/claudex/issues/93)) ([f3d039d](https://github.com/DennisKh/claudex/commit/f3d039d45792b6a85a6a80265a985f3a20861062))
* **tracing:** report provider and token counts the way the GenAI conventions define them ([#106](https://github.com/DennisKh/claudex/issues/106)) ([3168ea9](https://github.com/DennisKh/claudex/commit/3168ea9b1ba9c039ada2fbeef14eef5079f0c61d))


### Build System

* decode JSON with Jason and support Elixir 1.17 ([#123](https://github.com/DennisKh/claudex/issues/123)) ([9c2a471](https://github.com/DennisKh/claudex/commit/9c2a47129d5532f8a278fb21d97c95cf2495055b))

## [0.10.0](https://github.com/DennisKh/claudex/compare/v0.9.1...v0.10.0) (2026-09-20)


### Features

* **mcp:** support the MCP connector ([#70](https://github.com/DennisKh/claudex/issues/70)) ([fb46876](https://github.com/DennisKh/claudex/commit/fb46876a32430c5d1f54b4cb93525fa3bb47350f))
* session ids on spans, and two content-block accessors ([#72](https://github.com/DennisKh/claudex/issues/72)) ([8b5b58b](https://github.com/DennisKh/claudex/commit/8b5b58b33a38bcf03eb2d362b5ba4cd00d535dfd))
* **tracing:** emit OpenTelemetry spans ([#65](https://github.com/DennisKh/claudex/issues/65)) ([4c56a4b](https://github.com/DennisKh/claudex/commit/4c56a4bae23ea10ada665ffd2331cb2649131228))

## [0.9.1](https://github.com/DennisKh/claudex/compare/v0.9.0...v0.9.1) (2026-09-15)


### Bug Fixes

* **tool_runner:** describe a tool result JSON cannot carry ([#66](https://github.com/DennisKh/claudex/issues/66)) ([57fd487](https://github.com/DennisKh/claudex/commit/57fd487eed20e82b4dafab2e52911affbe728207))

## [0.9.0](https://github.com/DennisKh/claudex/compare/v0.8.1...v0.9.0) (2026-09-13)


### Features

* **client:** add build/1 and Model.supports?/2, read named spec args ([#57](https://github.com/DennisKh/claudex/issues/57)) ([d5717b8](https://github.com/DennisKh/claudex/commit/d5717b822563c7def224f4e318c45c3fa0478b30))
* **message:** answer how a reply ended, for a loop you drive yourself ([#53](https://github.com/DennisKh/claudex/issues/53)) ([09f7a6d](https://github.com/DennisKh/claudex/commit/09f7a6d648306c91b706f58bd056a738a1b97ff5))
* **mix:** add claudex.gen.tool ([#61](https://github.com/DennisKh/claudex/issues/61)) ([b0763b1](https://github.com/DennisKh/claudex/commit/b0763b19d55c40872d885f19dfe6a04c26cae77d))
* **streaming:** let a stream stop with the process it delivers to ([#63](https://github.com/DennisKh/claudex/issues/63)) ([722753c](https://github.com/DennisKh/claudex/commit/722753cef1dfbedf2b4b9b06d693a7d84844c93e))
* **tool_runner:** add stream_to/3 ([#62](https://github.com/DennisKh/claudex/issues/62)) ([8ae7366](https://github.com/DennisKh/claudex/commit/8ae736661ecef9c303b74db7d58958f0dfe13d45))


### Bug Fixes

* **tool:** report a tool call whoever is driving the loop ([#56](https://github.com/DennisKh/claudex/issues/56)) ([64c6e74](https://github.com/DennisKh/claudex/commit/64c6e74c6855d155fa92e8c200c8084749e79e5d))

## [0.8.1](https://github.com/DennisKh/claudex/compare/v0.8.0...v0.8.1) (2026-09-11)


### Bug Fixes

* **stream:** keep a server tool's arguments when they stream in ([#51](https://github.com/DennisKh/claudex/issues/51)) ([53f68b0](https://github.com/DennisKh/claudex/commit/53f68b0f64bb8d074d597fd701bce32c05998834))

## [0.8.0](https://github.com/DennisKh/claudex/compare/v0.7.0...v0.8.0) (2026-09-11)


### Features

* **content_block:** build the document and image blocks you send ([#44](https://github.com/DennisKh/claudex/issues/44)) ([c89f33b](https://github.com/DennisKh/claudex/commit/c89f33bea6507db040daa45c583639ae5d2e9ffe))
* **content_block:** decode the blocks server tools send back ([#41](https://github.com/DennisKh/claudex/issues/41)) ([f73af0f](https://github.com/DennisKh/claudex/commit/f73af0f3bbe2c2d98ad0fa5723762dbf119cfce0))
* **messages:** build output_config.format from a struct ([#42](https://github.com/DennisKh/claudex/issues/42)) ([38e69bd](https://github.com/DennisKh/claudex/commit/38e69bdb39865a27eff41cf1927cdb0250ae5103))
* **page:** walk every page, whichever cursor the endpoint uses ([#45](https://github.com/DennisKh/claudex/issues/45)) ([c62bb9c](https://github.com/DennisKh/claudex/commit/c62bb9c4543913f6cc02c628f3698999145cb6c6))
* **tool_runner:** stream each turn and report events to :on_event ([#36](https://github.com/DennisKh/claudex/issues/36)) ([dffb3ca](https://github.com/DennisKh/claudex/commit/dffb3cab39881a168bda5434f14129f837d520bd))


### Bug Fixes

* **tool_runner:** report a reply that ran out of room as truncated ([#47](https://github.com/DennisKh/claudex/issues/47)) ([f66dfc0](https://github.com/DennisKh/claudex/commit/f66dfc02fff31fd4bd1c076b977d2b0b9bc1cbb6))
* **tool_runner:** resume a turn the API paused ([#40](https://github.com/DennisKh/claudex/issues/40)) ([24d40c9](https://github.com/DennisKh/claudex/commit/24d40c97bb451321f029fc8530465eb345c2a4c5))

## [0.7.0](https://github.com/DennisKh/claudex/compare/v0.6.1...v0.7.0) (2026-09-09)


### Features

* **stream:** make usage merging, tool_uses and streamed text public ([#33](https://github.com/DennisKh/claudex/issues/33)) ([f50cd06](https://github.com/DennisKh/claudex/commit/f50cd06aca6a3bc237c65e08e4685eed679b26d0))
* **tool_runner:** gate tool calls with a before_call hook ([#32](https://github.com/DennisKh/claudex/issues/32)) ([080ad6d](https://github.com/DennisKh/claudex/commit/080ad6d130affa3e1d7d9de3d4d93d810bffdb66))
* **tool:** describe tool arguments without giving up schema inference ([#31](https://github.com/DennisKh/claudex/issues/31)) ([a44e250](https://github.com/DennisKh/claudex/commit/a44e2502ef8ec4077606c7d3359d6cc3a57e1d36))


### Bug Fixes

* **tool:** return a uniform error struct from Tool.call/3 ([#29](https://github.com/DennisKh/claudex/issues/29)) ([79aa940](https://github.com/DennisKh/claudex/commit/79aa940b597a2b72f1d3563c96630f43c76c8b59))
* **streaming:** cancel a stream immediately instead of at the next event ([#28](https://github.com/DennisKh/claudex/issues/28)) ([eadf02b](https://github.com/DennisKh/claudex/commit/eadf02bd730dfc0bdcac4fb0cff8bb0272317f9d))
* **telemetry:** report the request span for streaming requests too ([#27](https://github.com/DennisKh/claudex/issues/27)) ([129b002](https://github.com/DennisKh/claudex/commit/129b0028ae99b619c5d1ed1feea5b0703044081d))

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
