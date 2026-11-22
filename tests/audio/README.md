# 听见固定录音基线

测试从固定提交下载 sherpa-onnx 公开模型样例中的中、英、日、韩四段录音，在本地生成低音量、噪声、短句和拼接变体。录音和模型不存进听见仓库。输入和参考文本在 `sensevoice_regression.py` 中固定。

GitHub 的 Server contract test 工作流通过 CPU 跑 Silero 和 SenseVoice ONNX，输出 `sensevoice-audio.json`。报告按语言计算字错率或英文词错率，同时记录漏句、误出字和语种错误。无声样本有输出会让测试失败，错误率较基线增加超过一个百分点会标记为警告。

这份基线用于发现服务端识别回归。本机 Core ML 的准确率、首字延迟和端到端断句仍需用 iPhone 核对。拼接音频主要用于对比模型在长音频和语言切换时的表现，App 的跨段归属和防重复另有 Swift 回归用例。

使用 Windows 已安装的模型可通过 `--model-dir` 指向 SenseVoice 目录复跑。省略该参数时会将固定版本的模型下载到 `--cache`。
