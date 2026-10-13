# 企业 RuleSet 预设示例

`RuleSetPresets.example.json` 只演示公开 schema，并仅使用保留的 HTTPS 示例域名，不应
写入凭据、私有域名或真实规则地址。该预设目录不声明普通 RuleSet 的本地文件输入能力；
订阅 GEOIP 规则的本地 `file://` 模板在各平台的订阅编辑器中另行配置。

实际构建配置应保存在仓库外或企业私有仓库中，并在构建时通过
`XDIAL_RULE_SET_PRESETS_FILE=/absolute/path/RuleSetPresets.json` 注入。未设置该变量时，
构建脚本只尝试读取被忽略的 `macos/PrivateConfig/RuleSetPresets.json`；两处都不存在时，
应用使用内建的空白预设。

## 首启预置 Profile

企业包可在构建时通过 `XDIAL_SEED_PROFILE_FILE=/absolute/path/SeedProfile.json` 注入一份
可移植 Profile 文档（与「导出配置」格式相同）；未设置时只尝试读取被忽略的
`macos/PrivateConfig/SeedProfile.json`。显式指定的文件不存在时构建失败。

该文档只在共享配置库和旧版配置都不存在时导入一次，生成首个配置及其场景；已有配置的
机器不会被替换或合并，之后的更新包也不再读取它。文档不得包含密码等凭据，用户首次连接前
在线路中自行填写。Next 分发包不嵌入预置 Profile。
