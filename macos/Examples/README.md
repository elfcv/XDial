# 企业 RuleSet 预设示例

`RuleSetPresets.example.json` 只演示公开 schema，并仅使用保留的 HTTPS 示例域名，不应
写入凭据、私有域名或真实规则地址。该预设目录不声明普通 RuleSet 的本地文件输入能力；
订阅 GEOIP 规则的本地 `file://` 模板在各平台的订阅编辑器中另行配置。

实际构建配置应保存在仓库外或企业私有仓库中，并在构建时通过
`XDIAL_RULE_SET_PRESETS_FILE=/absolute/path/RuleSetPresets.json` 注入。未设置该变量时，
构建脚本只尝试读取被忽略的 `macos/PrivateConfig/RuleSetPresets.json`；两处都不存在时，
应用使用内建的空白预设。

## 预置 Profile

企业包可在构建时通过 `XDIAL_SEED_PROFILE_FILE=/absolute/path/<名称>.json` 注入一份可移植
Profile 文档（与「导出配置」格式相同）；未设置时只尝试读取被忽略的
`macos/PrivateConfig/SeedProfile/<名称>.json`。文件名即 Profile 名称，与「从文件导入」一致。
显式指定的文件不存在或不是 `.json` 时构建失败。Next 分发包不嵌入预置 Profile。

同名预置在共享配置目录的 `seed-profiles.json` 中记录它对应的 Profile 和内容指纹；该记录不写进
配置库，因为旧版本保存配置库时会丢弃不认识的字段。

- 配置库和旧版配置都不存在时，以它创建首个配置，场景保持原名。
- 已有配置库且尚未记录时，像「从文件导入」一样把它加在现有 Profile 旁边，场景以「<名称> · <场景>」
  加入；不改变当前场景、正在编辑的配置或运行中的连接。
- 已记录且内容变化时，像订阅刷新一样覆盖它拥有的线路、规则和场景路由，保留用户填写的密码等凭据、
  场景名称和图标；新增场景照常加入，预置不再声明的场景作为用户自己的场景保留。
- 用户删除了对应 Profile 时不再加入。
- 已被其他场景占用的 Wi-Fi 触发留在原场景，预置场景上去掉该触发。

文档不得包含密码等凭据，用户首次连接前在线路中自行填写。
