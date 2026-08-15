# Third-party notices

The repository's project code and documentation are distributed under the root [MIT License](LICENSE), except for third-party material identified below. A project-level license does not replace the license terms attached to third-party material.

## GodotHair reference implementation

Parts of this project were developed from and against the open-source **GodotHair** reference implementation by Ethan Truong (`2Retr0/GodotHair`). GodotHair is licensed under the MIT License.

Source: https://github.com/2Retr0/GodotHair

Upstream notice:

```text
MIT License

Copyright (c) 2025 Ethan Truong

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Demo hair-card models and groom maps

The demo hair assets under:

```text
assets/hair/models/**
```

originate from the hair dataset distributed with **CT2Hair** by Meta Research and were adapted into hair-card assets by the GodotHair project. The GodotHair README identifies those hair-card meshes as adaptations of the CT2Hair dataset and makes them available under **Creative Commons Attribution-NonCommercial 4.0 International (CC BY-NC 4.0)**.

Original dataset/source:

- CT2Hair: https://github.com/facebookresearch/CT2Hair
- CT2Hair license: https://creativecommons.org/licenses/by-nc/4.0/
- GodotHair adaptation/source: https://github.com/2Retr0/GodotHair

The conversion history described by GodotHair is: CT2Hair strand data -> Alembic strand data -> Unreal Engine 5 Hair Card Generator -> Godot hair-card meshes. This repository additionally contains Godot import/packaging data associated with those assets.

These demo hair-card models and their associated generated groom textures are **not covered by this repository's MIT license**. They remain subject to CC BY-NC 4.0, including its attribution and non-commercial-use conditions.

Attribution:

> CT2Hair by Yuefan Shen, Shunsuke Saito, Ziyan Wang, Olivier Maury, Chenglei Wu, Jessica Hodgins, Youyi Zheng, and Giljoo Nam / Meta Research. Adapted into the GodotHair hair-card demo dataset by Ethan Truong. Licensed under CC BY-NC 4.0. Further Godot integration/packaging changes are present in this repository.

The distributable `release/0.1.0` addon package does **not** include `assets/hair/models/**`; therefore these CC BY-NC demo assets are not part of the standalone `addons/marschner_hair/` runtime distribution.
