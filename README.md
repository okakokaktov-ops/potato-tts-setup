# TTS на картошке

## Установка
Cкачать Git Bash
``` powershell
winget install --id Git.Git -e --source winget
```
Далее открываем Git Bash, переходим в нужную директорию
```
cd YourDisk:\path\you\want
```
Затем запускаем скрипт
```
CUDA_ARCH=** ./setup_q4km.sh  # ** --> 61 = Pascal (GTX 10xx), 75 = Turing (RTX 20xx / GTX 16xx), 86 = Ampere (RTX 30xx), 89 = Ada (RTX 40xx)
```

## Клонирование
![warning](warning.jpg)
В созданную папку ref переносим референс аудио (audio_ref.mp3) с его расшифровкой в отдельном текстовом файле (text_ref.txt). Аудио может иметь .mp3/.raw желательно длиною меньше 10 секунд.
```
python ptmaker.py
```

## Генерация
```
python tts.py
```
Генерируемый текст берется из текстового файла tosintez. Аудио сохраняется в папке synthesized.

Все мозги системы расположены в папке engine.
(В папке engine\omnivoice-gguf\ лежит .rvq клонированного голоса, после каждого клона он перезаписывается, если хотите сохранить голос, клонируя другой, то переместите его в другое место или переименуйте)
