# Working with Unity projects

Open the Unity project folder in Tamtoot to edit its text sources. This update
adds editing aids on Windows, macOS and Linux; it does not connect to Unity's
Editor process or add Play mode, asset import, builds or Unity debugging.

## Scripts and assemblies

In the new-file dialog choose C# and a Unity template:

- **Unity MonoBehaviour**: component with Awake and Update callbacks.
- **Unity ScriptableObject**: asset type with a serialized value and CreateAssetMenu.
- **Unity EditorWindow**: menu entry and editor window, guarded by UNITY_EDITOR.
  Save in an `Editor` folder or an Editor-only assembly.

The filename supplies the class name. Keep component filenames and class names
matched. Templates use UnityEngine / UnityEditor supplied by Unity, not NuGet.
Use the Unity Editor to compile and validate them with your project's version.

C# snippets use the `unity-` prefix: `awake`, `start`, `update`, `fixedupdate`,
`enable`, `serialize`, `require`, `coroutine`, `trigger`, `trigger2d`, `collision`,
`tryget`, `gizmos`, and `log`. Callback snippets belong inside a MonoBehaviour;
`unity-require` goes above the class declaration. Snippets do not discover your
scene objects or provide compiler-backed member completion.

Under JSON, **Unity assembly definition** and **Unity Editor-only assembly
definition** create `.asmdef` files. Add references appropriate to your assembly
boundaries; the templates start with an empty references list. `.asmref` and
`.inputactions` also select JSON coloring. See Unity's
[assembly definition documentation](https://docs.unity.cn/2019.2/Documentation/Manual/ScriptCompilationAssemblyDefinitionFiles.html)
and [CreateAssetMenu reference](https://docs.unity.com/en-us/engine/6000.5/script-reference/unityengine/createassetmenuattribute).

## Shaders

**Unity ShaderLab / HLSL** colors `.shader`, `.hlsl`, `.hlsli`, `.cginc` and
`.compute` files, including comments, directives, scalar/vector/matrix types,
resource types, ShaderLab blocks and shader semantics such as SV_POSITION.
Bracket pairing and comment toggling are available. `hlsl-cbuffer` and
`hlsl-kernel` provide small code snippets.

- **Unity Built-in unlit shader** targets the Built-in Render Pipeline. It is
  not a URP/HDRP shader; adapt pipeline includes and pass tags for those pipelines.
- **Unity compute shader** supplies a guarded buffer-write kernel. Bind a float
  buffer named Result and dispatch from Unity; shader creation alone does not
  allocate buffers or run the GPU code. Platform compute support is required.

Coloring is lexical, not shader compilation or pipeline validation. Consult the
[ShaderLab code-block reference](https://docs.unity.com/en-us/engine/6000.0/manual/materials-and-shaders/shaders/reference/sl-reference/sl-sub-shader-pass/shader-shaderlab-code-blocks)
and [compute shader manual](https://docs.unity.cn/Manual/class-ComputeShader.html).

## Serialized assets

Text `.unity`, `.prefab`, `.meta`, `.asset`, `.mat`, `.anim`, `.controller`,
`.overridecontroller`, `.playable`, `.rendertexture`, `.terrainlayer`, `.lighting`
and `.spriteatlas` files select YAML coloring. This applies to text serialization;
Unity can also produce binary assets with these extensions. It does not convert
binary files or validate Unity references. Preserve GUIDs in meta files.

`.shadergraph` and `.shadersubgraph` use JSON coloring. Some versions serialize
multiple JSON objects; coloring does not imply the whole file is one JSON document.
There is no graph canvas or scene/prefab inspector in Tamtoot. Use Unity to edit
object relationships and import assets.

[Regression coverage and local syntax performance measurements](unity-performance.md).
