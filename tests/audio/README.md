# 听见固定录音基线

测试从固定提交下载 sherpa-onnx 公开模型样例中的中、英、日、韩四段录音，在本地生成低音量、噪声、短句和拼接变体。录音和模型不存进听见仓库。输入和参考文本在 `sensevoice_regression.py` 中固定。

GitHub 的 Server contract test 工作流通过 CPU 跑 Silero 和 SenseVoice ONNX，输出 `sensevoice-audio.json`。报告按语言计算字错率或英文词错率，同时记录漏句、误出字和语种错误。无声样本有输出会让测试失败，错误率较基线增加超过一个百分点会标记为警告。

这份基线用于发现服务端识别回归。本机 Core ML 的准确率、首字延迟和端到端断句仍需用 iPhone 核对。拼接音频主要用于对比模型在长音频和语言切换时的表现，App 的跨段归属和防重复另有 Swift 回归用例。

使用 Windows 已安装的模型可通过 `--model-dir` 指向 SenseVoice 目录复跑。省略该参数时会将固定版本的模型下载到 `--cache`。

## iPhone 对照

在 GitHub 的 Check build 工作流下载 `Hear-Speech-Regression`，解压后按日常方式签名安装 IPA。安装本机 SenseVoice，结束录音，然后打开「功能设置 → 语言和日志 → 本机语音回归测试」。运行后可分享 JSON。首次运行会下载四段固定来源的公开录音并派生变体。噪声变体在 iPhone 和服务端使用各自固定的生成方式，适合同设备前后比较。

报告记录模型重载耗时、重载后首次推理、每个片段实际的识别耗时、字词错误率和采样边界。断句测试使用 App 的 Silero 和 Segmenter，对同一组输入分别运行 300 ms 和 450 ms 前置缓冲。`firstPreviewAtMs` 是固定录音内首次触发预览的位置，`firstPreviewInferenceMs` 是该快照的推理耗时。实际开麦到首字仍通过真机实时翻译测量。

先比较轻声样本的首字和整句是否保留，再查看静音误出字、边界重叠和普通样本首个预览的位置。正式构建继续使用 300 ms，等真机比较确认收益再决定默认值。
