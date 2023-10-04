//using System;
using System.Collections.Generic;
using System.Collections.Immutable;
using System.Linq;
using System.Text.RegularExpressions;
using UnityEditor;
using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.UIElements;
using VF.Builder;
using VF.Feature.Base;
using VF.Injector;
using VF.Inspector;
using VF.Model.Feature;
using VF.Service;
using VF.Utils;

namespace VF.Feature {
    //TODO: Make TpsScaleFixBuider a wrapper around this
    public class MaterialPropertyScaleFixBuilder : FeatureBuilder<MaterialPropertyScaleFix> {
        [VFAutowired] private readonly ScalePropertyCompensationService scaleCompensationService;

        public override string GetEditorTitle() {
            return "Material Property Scaling Fix";
        }

        public override VisualElement CreateEditor(SerializedProperty prop) {
            var content = new VisualElement {
                style = {
                    flexDirection = FlexDirection.Row,
                    alignItems = Align.FlexStart
                }
            };

            var label = new Label("Material Property") {
                style = {
                    flexGrow = 0,
                    flexBasis = 100
                }
            };

            var col = new VisualElement {
                style =
                {
                    flexDirection = FlexDirection.Column,
                    flexGrow = 1
                }
            };

            content.Add(label);

            var rendererRow = new VisualElement {
                style = {
                    flexDirection = FlexDirection.Row,
                    alignItems = Align.Center,
                    marginBottom = 1
                }
            };

            var affectAllMeshesProp = prop.FindPropertyRelative("affectAllMeshes");

            var rendererProp = prop.FindPropertyRelative("renderer");
            var propField = VRCFuryEditorUtils.Prop(rendererProp);
            propField.style.flexGrow = 1;
            propField.style.flexShrink = 1;
            propField.SetEnabled(!affectAllMeshesProp.boolValue);
            rendererRow.Add(propField);

            rendererRow.Add(new Label("All Skinned Meshes") {
                style = {
                    marginLeft = 2,
                    marginRight = 2,
                    flexGrow = 1,
                    flexBasis = 120,
                    unityTextAlign = TextAnchor.MiddleRight
                }
            });

            var propField4 = VRCFuryEditorUtils.RefreshOnChange(() => {
                propField.SetEnabled(!affectAllMeshesProp.boolValue);
                var field = VRCFuryEditorUtils.Prop(affectAllMeshesProp);
                return field;
            }, affectAllMeshesProp);
            propField4.style.flexGrow = 0;
            propField4.style.flexShrink = 0;
            propField4.style.flexBasis = 16;
            rendererRow.Add(propField4);

            col.Add(rendererRow);

            var materialRow = new VisualElement {
                style = {
                    flexDirection = FlexDirection.Row,
                    alignItems = Align.FlexStart
                }
            };

            var propertyNameProp = prop.FindPropertyRelative("propertyName");
            var propField2 = VRCFuryEditorUtils.Prop(propertyNameProp);
            propField2.style.flexGrow = 1;
            propField2.tooltip = "Property Name";
            materialRow.Add(propField2);

            var searchButton = new Button(SearchClick) {
                text = "Search",
                style =
                {
                    marginTop = 0,
                    marginLeft = 0,
                    marginRight = 0,
                    marginBottom = 0
                }
            };
            materialRow.Add(searchButton);
            col.Add(materialRow);

            content.Add(col);

            return content;

            //TODO, make regular functions
            //Can we just pass object? or would the button need refressing if we do?
            void SearchClick() {
                var targetWidth = content.GetFirstAncestorOfType<UnityEditor.UIElements.InspectorElement>().worldBound
                    .width;
                var searchContext = new UnityEditor.Experimental.GraphView.SearchWindowContext(GUIUtility.GUIToScreenPoint(Event.current.mousePosition), targetWidth, 300);
                var provider = ScriptableObject.CreateInstance<VRCFurySearchWindowProvider>();
                provider.InitProvider(GetTreeEntries, (entry, userData) => {
                    propertyNameProp.stringValue = (string)entry.userData;
                    prop.serializedObject.ApplyModifiedProperties();
                    return true;
                });
                UnityEditor.Experimental.GraphView.SearchWindow.Open(searchContext, provider);
            }

            List<UnityEditor.Experimental.GraphView.SearchTreeEntry> GetTreeEntries() {
                var entries = new List<UnityEditor.Experimental.GraphView.SearchTreeEntry> {
                    new UnityEditor.Experimental.GraphView.SearchTreeGroupEntry(new GUIContent("Material Properties"))
                };
                var renderers = new List<Renderer>();
                if (affectAllMeshesProp.boolValue) {
                    if (avatarObject != null) {
                        renderers.AddRange(avatarObject.GetComponentsInSelfAndChildren<SkinnedMeshRenderer>());
                    }
                } else {
                    renderers.Add(rendererProp.objectReferenceValue as SkinnedMeshRenderer);
                }

                if (renderers.Count == 0) return entries;

                var singleRenderer = renderers.Count == 1;
                foreach (var renderer in renderers) {
                    if (renderer == null) continue;
                    var nest = 1;
                    var sharedMaterials = renderer.sharedMaterials;
                    if (sharedMaterials.Length == 0) return entries;
                    var singleMaterial = sharedMaterials.Length == 1;
                    if (!singleRenderer) {
                        entries.Add(new UnityEditor.Experimental.GraphView.SearchTreeGroupEntry(new GUIContent("Mesh: " + GetPath(renderer.owner())), nest));
                    }
                    foreach (var material in sharedMaterials) {
                        if (material == null) continue;

                        nest = singleRenderer ? 1 : 2;
                        if (!singleMaterial) {
                            entries.Add(new UnityEditor.Experimental.GraphView.SearchTreeGroupEntry(new GUIContent("Material: " + material.name), nest));
                            nest++;
                        }
                        var shader = material.shader;

                        if (shader == null) continue;

                        var count = ShaderUtil.GetPropertyCount(shader);
                        var materialProperties = MaterialEditor.GetMaterialProperties(new Object[] { material });
                        for (var i = 0; i < count; i++) {
                            var propertyName = ShaderUtil.GetPropertyName(shader, i);
                            var readableName = ShaderUtil.GetPropertyDescription(shader, i);
                            var matProp = System.Array.Find(materialProperties, p => p.name == propertyName);
                            if ((matProp.flags & MaterialProperty.PropFlags.HideInInspector) != 0) continue;

                            var propType = ShaderUtil.GetPropertyType(shader, i);

                            if (propType != ShaderUtil.ShaderPropertyType.Float &&
                                propType != ShaderUtil.ShaderPropertyType.Range &&
                                propType != ShaderUtil.ShaderPropertyType.Vector) continue;

                            var prioritizePropName = readableName.Length > 25f;
                            var entryName = prioritizePropName ? propertyName : readableName;
                            if (!singleRenderer) {
                                entryName += $" (Mesh: {GetPath(renderer.owner())})";
                            }
                            if (!singleMaterial) {
                                entryName += $" (Mat: {material.name})";
                            }

                            entryName += prioritizePropName ? $" ({readableName})" : $" ({propertyName})";
                            entries.Add(new UnityEditor.Experimental.GraphView.SearchTreeEntry(new GUIContent(entryName)) {
                                level = nest,
                                userData = propertyName
                            });
                        }
                    }
                }
                return entries;
            }
        }

        public override bool AvailableOnProps() {
            return false;
        }

        string GetPath(VFGameObject obj) {
            return avatarObject == null ? obj.name : obj.GetPath(avatarObject);
        }

        [FeatureBuilderAction(FeatureOrder.TpsScaleFix)]
        public void Apply() {
            if (model.renderer == null && !model.affectAllMeshes) return;
            var renderers = new[] { model.renderer };
            if (model.affectAllMeshes) {
                renderers = avatarObject.GetComponentsInSelfAndChildren<SkinnedMeshRenderer>();
            }

            foreach (var renderer in renderers) {
                VFGameObject rootBone = renderer.transform;
                if (renderer is SkinnedMeshRenderer skin && skin.rootBone != null) {
                    rootBone = skin.rootBone;
                }

                var scaledProps = GetScaledProps(renderer.sharedMaterials, model.propertyName);
                var props = scaledProps.Select(p => (renderer.owner(), renderer.GetType(), $"material.{p.Key}", p.Value));
                scaleCompensationService.AddScaledProp(rootBone, props);
            }
        }

        private static Dictionary<string, float> GetScaledProps(IEnumerable<Material> materials, string propertyName) {
            var scaledProps = new Dictionary<string, float>();
            foreach (var mat in materials) {
                void Add(string propName, float val) {
                    if (scaledProps.TryGetValue(propName, out var oldVal) && val != oldVal) {
                        throw new System.Exception(
                            "This renderer contains multiple materials with different scale values");
                    }
                    scaledProps[propName] = val;
                }

                void AddVector(string propName) {
                    if (!mat.HasProperty(propName)) return;
                    var val = mat.GetVector(propName);
                    Add(propName + ".x", val.x);
                    Add(propName + ".y", val.y);
                    Add(propName + ".z", val.z);
                }
                void AddFloat(string propName) {
                    if (!mat.HasProperty(propName)) return;
                    var val = mat.GetFloat(propName);
                    Add(propName, val);
                }

                var shader = mat.shader;
                if (shader == null) continue;

                int i = shader.FindPropertyIndex(propertyName);
                if (i == -1) continue;

                var propType = shader.GetPropertyType(i);

                if (propType == ShaderPropertyType.Float |
                    propType == ShaderPropertyType.Range) {
                    AddFloat(propertyName);
                } else if (propType == ShaderPropertyType.Vector) {
                    AddVector(propertyName);
                }
            }
            return scaledProps;
        }
    }
}
