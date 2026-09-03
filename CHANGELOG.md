# Changelog

## [0.0.12](https://github.com/bo0tzz/loopdedupe/compare/v0.0.11...v0.0.12) (2026-09-03)


### Features

* **bot:** reply with similar items on [@loopdedupe](https://github.com/loopdedupe) mention ([adb6f65](https://github.com/bo0tzz/loopdedupe/commit/adb6f65cbb32cca0b30a67bdc153bc773a88525f))
* **dashboard:** show type and status on candidates, with a status filter ([53c12a0](https://github.com/bo0tzz/loopdedupe/commit/53c12a0fae333b12fa7d1e805962db7602a3aec3)), closes [#24](https://github.com/bo0tzz/loopdedupe/issues/24)


### Bug Fixes

* **bot:** link suggestions via redirect.github.com ([084fbdb](https://github.com/bo0tzz/loopdedupe/commit/084fbdb3823f5992ce0e62f2233ed06c08f3b2ce))
* **github:** read the canonical from Issue.duplicateOf ([38b9f75](https://github.com/bo0tzz/loopdedupe/commit/38b9f75707a52e3e511fd4537edb58d711a6903d))
* **rerank:** clamp per-doc length to stay under voyage's batch cap ([f57bd6f](https://github.com/bo0tzz/loopdedupe/commit/f57bd6f3847a2e320c3d20d6bc8bf312acd61646))

## [0.0.11](https://github.com/bo0tzz/loopdedupe/compare/v0.0.10...v0.0.11) (2026-07-21)


### Features

* **search:** expose number + item_type instead of github_id ([600a065](https://github.com/bo0tzz/loopdedupe/commit/600a065e947fc20509d554e922031e29bf611226))

## [0.0.10](https://github.com/bo0tzz/loopdedupe/compare/v0.0.9...v0.0.10) (2026-07-20)


### Features

* **search:** ad-hoc similarity search over the corpus ([1922daa](https://github.com/bo0tzz/loopdedupe/commit/1922daa9ca34b1b881bea1be209d943087efd702))


### Bug Fixes

* **embeddings:** short-circuit when item already has a fresh embedding ([6ce7bae](https://github.com/bo0tzz/loopdedupe/commit/6ce7baea3076d18300ba9288e9010def250231e9))

## [0.0.9](https://github.com/bo0tzz/loopdedupe/compare/v0.0.8...v0.0.9) (2026-06-15)


### Bug Fixes

* **github:** prefer html_url over url when decoding items ([76101b0](https://github.com/bo0tzz/loopdedupe/commit/76101b02feba815e74c26bdfdeffc639e6dcced9))

## [0.0.8](https://github.com/bo0tzz/loopdedupe/compare/v0.0.7...v0.0.8) (2026-06-13)


### Bug Fixes

* chain across kinds for items.duplicate_of_number ([e8d75f1](https://github.com/bo0tzz/loopdedupe/commit/e8d75f1ef0f3fc77539af3fd83ad1a0c47c77386))

## [0.0.7](https://github.com/bo0tzz/loopdedupe/compare/v0.0.6...v0.0.7) (2026-06-03)


### Features

* **dashboard:** show recent items above top candidates ([58a5d36](https://github.com/bo0tzz/loopdedupe/commit/58a5d3675e22f5a59d09b259ebe3e8da1716aaf0))


### Bug Fixes

* **dashboard:** nowrap recent-items date column ([fee8470](https://github.com/bo0tzz/loopdedupe/commit/fee84704e435d7a1c469c7661876a7777edc1648))

## [0.0.6](https://github.com/bo0tzz/loopdedupe/compare/v0.0.5...v0.0.6) (2026-06-03)


### Bug Fixes

* bind to 0.0.0.0 instead of localhost so the container is reachable ([33a71fa](https://github.com/bo0tzz/loopdedupe/commit/33a71fa8934a2fc8e96a08d3fcbc3cbbbe9f17fe))

## [0.0.5](https://github.com/bo0tzz/loopdedupe/compare/v0.0.4...v0.0.5) (2026-06-02)


### Features

* **routes:** /issues/N and /discussions/N redirect to candidate detail ([61a1d79](https://github.com/bo0tzz/loopdedupe/commit/61a1d79dfd114c38ec284c3edaf14422fbbc6082))

## [0.0.4](https://github.com/bo0tzz/loopdedupe/compare/v0.0.3...v0.0.4) (2026-06-02)


### Features

* **auth:** support GitHub App authentication in addition to PAT ([dc79bf0](https://github.com/bo0tzz/loopdedupe/commit/dc79bf093ad649cc70ae416eded5bb061822b2d1))

## [0.0.3](https://github.com/bo0tzz/loopdedupe/compare/v0.0.2...v0.0.3) (2026-06-02)


### Bug Fixes

* **release-please:** use PAT so the tag push triggers build.yml ([1ebe897](https://github.com/bo0tzz/loopdedupe/commit/1ebe89739f926d6c546d02bdcb3e547d405e63d2))

## [0.0.2](https://github.com/bo0tzz/loopdedupe/compare/v0.0.1...v0.0.2) (2026-06-02)


### Bug Fixes

* regenerate sql.gleam after suggest_duplicates LIMIT bump ([d8f02a7](https://github.com/bo0tzz/loopdedupe/commit/d8f02a74a58bcdf196278a4f42b3889d1ce834c8))
