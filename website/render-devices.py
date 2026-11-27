#!/usr/bin/env python3
"""
Render 4K (3840x2880) Ultramock-grade high-contrast dark-studio product photography for
monoid.build / monoid.zone #devices using official manufacturer 3D CAD models + 4K Poly Haven
CC0 studio softbox HDRI (.exr) + Cycles GPU (OptiX/CUDA) raytracing:
  - duo:     Apple official iPhone 18 Pro Max USDZ (Natural Titanium CNC rail, real 3D Dynamic Island)
  - android: Samsung official Galaxy S25+ GLB (large concentric rounded corners, metallic navy)
  - desk:    Apple official MacBook Air 15" Silver USDZ (ultra-thin 11.5mm unibody, matte black keycaps)
  - web:     27" 4K Workstation Display running Windows 11 + Edge/Chrome app.monoid.build

Optical & material engineering:
  - Unified Ultramock luxury dark studio across all 4 devices: 4K Poly Haven studio softbox EXR HDRI
    drives CNC metallic/glass specular reflections, separated via Light Path (Is Camera Ray) from a
    sculpted dark obsidian backdrop + satin dark architectural plinth catching soft screen glow.
  - Noise-free `Emit` pass separated BEFORE OpenImageDenoise AND BEFORE filmic highlight rolloff:
    `Final = SoftShoulder(Denoise(Combined - Emit)) + Emit`
    so CNC aluminum/titanium highlights roll off photographically with ZERO blown-out white clipping
    while every 8pt CJK/Latin UI glyph stays pixel-exact `#F5F3EF` and razor-sharp at 4K!
"""

import bpy
import math
import mathutils
import os
import sys


def parse_args():
    argv = sys.argv
    argv = argv[argv.index("--") + 1:] if "--" in argv else []
    opts = {
        "models_dir": ".",
        "screens_dir": "./screens",
        "out_dir": "./renders",
        "devices": ["duo", "android", "desk", "web"],
        "langs": ["en"],
        "width": 3840,
        "height": 2880,
        "samples": 64,
    }
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--models":
            opts["models_dir"] = argv[i + 1]; i += 2
        elif a == "--screens":
            opts["screens_dir"] = argv[i + 1]; i += 2
        elif a == "--out":
            opts["out_dir"] = argv[i + 1]; i += 2
        elif a == "--devices":
            opts["devices"] = argv[i + 1].split(","); i += 2
        elif a == "--langs":
            opts["langs"] = argv[i + 1].split(","); i += 2
        elif a == "--samples":
            opts["samples"] = int(argv[i + 1]); i += 2
        elif a == "--size":
            w, h = argv[i + 1].split("x")
            opts["width"], opts["height"] = int(w), int(h); i += 2
        else:
            i += 1
    return opts


def configure_device(sc):
    prefs = bpy.context.preferences.addons['cycles'].preferences
    for backend in ('OPTIX', 'CUDA'):
        try:
            prefs.compute_device_type = backend
            prefs.get_devices()
            gpus = [d for d in prefs.devices if d.type == backend]
            if gpus:
                for d in prefs.devices:
                    d.use = (d.type == backend)
                sc.cycles.device = 'GPU'
                print(f"[cycles] using GPU backend={backend} devices={[d.name for d in gpus]}")
                return
        except Exception:
            pass
    sc.cycles.device = 'CPU'
    print("[cycles] fallback to CPU")


def reset_scene(w, h, samples):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    sc = bpy.context.scene
    sc.render.engine = 'CYCLES'
    configure_device(sc)
    sc.cycles.samples = samples
    sc.cycles.use_adaptive_sampling = True
    sc.cycles.adaptive_threshold = 0.012
    sc.cycles.use_denoising = False  # Handled in Compositor AFTER separating Emit!
    sc.cycles.max_bounces = 8
    sc.cycles.diffuse_bounces = 4
    sc.cycles.glossy_bounces = 6
    sc.cycles.transmission_bounces = 6
    sc.cycles.transparent_max_bounces = 8
    sc.cycles.sample_clamp_indirect = 4.0
    sc.cycles.pixel_filter_type = 'BLACKMAN_HARRIS'
    sc.cycles.filter_width = 0.72

    sc.render.resolution_x = w
    sc.render.resolution_y = h
    sc.render.resolution_percentage = 100
    sc.render.image_settings.file_format = 'PNG'
    sc.render.image_settings.color_mode = 'RGB'
    sc.render.image_settings.color_depth = '8'

    sc.view_settings.view_transform = 'Standard'
    sc.view_settings.look = 'None'
    sc.view_settings.exposure = 0.0
    sc.view_settings.gamma = 1.0

    vl = sc.view_layers[0]
    vl.use_pass_combined = True
    vl.use_pass_emit = True
    vl.cycles.denoising_store_passes = True

    # Zero-blur Compositor with Filmic Soft-Shoulder ONLY on Hardware (non-Emit) branch:
    #   H = Denoise(Combined - Emit)
    #   H_filmic = H / (1.0 + 0.42 * H)   # smooth photographic highlight roll-off, zero blown-out white!
    #   Final = H_filmic + Emit            # pixel-exact un-denoised 4K UI screen!
    sc.use_nodes = True
    nt = sc.node_tree
    nt.nodes.clear()

    rl = nt.nodes.new('CompositorNodeRLayers')

    sub = nt.nodes.new('CompositorNodeMixRGB')
    sub.blend_type = 'SUBTRACT'
    sub.inputs['Fac'].default_value = 1.0

    den = nt.nodes.new('CompositorNodeDenoise')
    den.prefilter = 'ACCURATE'
    den.use_hdr = True

    # Analytic Reinhard soft-shoulder: H / (1 + 0.42 * H)
    mul_k = nt.nodes.new('CompositorNodeMixRGB')
    mul_k.blend_type = 'MULTIPLY'
    mul_k.inputs['Fac'].default_value = 1.0
    mul_k.inputs[2].default_value = (0.42, 0.42, 0.42, 1.0)

    add_one = nt.nodes.new('CompositorNodeMixRGB')
    add_one.blend_type = 'ADD'
    add_one.inputs['Fac'].default_value = 1.0
    add_one.inputs[2].default_value = (1.0, 1.0, 1.0, 1.0)

    div_soft = nt.nodes.new('CompositorNodeMixRGB')
    div_soft.blend_type = 'DIVIDE'
    div_soft.inputs['Fac'].default_value = 1.0

    add_emit = nt.nodes.new('CompositorNodeMixRGB')
    add_emit.blend_type = 'ADD'
    add_emit.inputs['Fac'].default_value = 1.0

    comp = nt.nodes.new('CompositorNodeComposite')

    nt.links.new(rl.outputs['Image'], sub.inputs[1])
    nt.links.new(rl.outputs['Emit'], sub.inputs[2])
    nt.links.new(sub.outputs['Image'], den.inputs['Image'])
    nt.links.new(rl.outputs['Denoising Normal'], den.inputs['Normal'])
    nt.links.new(rl.outputs['Denoising Albedo'], den.inputs['Albedo'])

    nt.links.new(den.outputs['Image'], mul_k.inputs[1])
    nt.links.new(mul_k.outputs['Image'], add_one.inputs[1])
    nt.links.new(den.outputs['Image'], div_soft.inputs[1])
    nt.links.new(add_one.outputs['Image'], div_soft.inputs[2])

    nt.links.new(div_soft.outputs['Image'], add_emit.inputs[1])
    nt.links.new(rl.outputs['Emit'], add_emit.inputs[2])
    nt.links.new(add_emit.outputs['Image'], comp.inputs['Image'])

    return sc


def build_studio(models_dir, scale_cm=True, hdri_rot_deg=35.0, top_energy=15.0, rim_energy=24.0):
    """Build Ultramock-grade high-contrast dark studio with real 4K Poly Haven studio softbox HDRI
    for metallic/glass reflections + satin dark smoked-obsidian architectural plinth."""
    u = 100.0 if scale_cm else 1.0

    world = bpy.data.worlds.new("StudioHDRIWorld")
    bpy.context.scene.world = world
    world.use_nodes = True
    wn = world.node_tree.nodes
    wl = world.node_tree.links
    wn.clear()

    out = wn.new('ShaderNodeOutputWorld')
    mix_sh = wn.new('ShaderNodeMixShader')
    lp = wn.new('ShaderNodeLightPath')

    # Lighting/reflection branch: real 4K Poly Haven studio softbox EXR!
    bg_refl = wn.new('ShaderNodeBackground')
    bg_refl.inputs['Strength'].default_value = 1.05
    hdri_path = os.path.join(models_dir, "hdri", "studio_small_09_4k.exr")
    if os.path.exists(hdri_path):
        tc = wn.new('ShaderNodeTexCoord')
        mp = wn.new('ShaderNodeMapping')
        mp.inputs['Rotation'].default_value = (0.0, 0.0, math.radians(hdri_rot_deg))
        env = wn.new('ShaderNodeTexEnvironment')
        env.image = bpy.data.images.load(hdri_path)
        wl.new(tc.outputs['Generated'], mp.inputs['Vector'])
        wl.new(mp.outputs['Vector'], env.inputs['Vector'])
        wl.new(env.outputs['Color'], bg_refl.inputs['Color'])
    else:
        bg_refl.inputs['Color'].default_value = (0.35, 0.34, 0.33, 1.0)

    # Camera background branch: deep luxury obsidian-charcoal
    bg_cam = wn.new('ShaderNodeBackground')
    bg_cam.inputs['Color'].default_value = (0.014, 0.014, 0.017, 1.0)
    bg_cam.inputs['Strength'].default_value = 1.0

    wl.new(lp.outputs['Is Camera Ray'], mix_sh.inputs['Fac'])
    wl.new(bg_refl.outputs['Background'], mix_sh.inputs[1])
    wl.new(bg_cam.outputs['Background'], mix_sh.inputs[2])
    wl.new(mix_sh.outputs['Shader'], out.inputs['Surface'])

    # Satin dark architectural smoked-walnut / obsidian studio plinth
    wood_dir = os.path.join(models_dir, "wood")
    mat_desk = bpy.data.materials.new("DarkStudioPlinth")
    mat_desk.use_nodes = True
    nt = mat_desk.node_tree
    nt.nodes.clear()
    m_out = nt.nodes.new('ShaderNodeOutputMaterial')
    bsdf = nt.nodes.new('ShaderNodeBsdfPrincipled')
    bsdf.inputs['IOR'].default_value = 1.50
    bsdf.inputs['Specular IOR Level'].default_value = 0.45
    bsdf.inputs['Coat Weight'].default_value = 0.36
    bsdf.inputs['Coat Roughness'].default_value = 0.12

    tc = nt.nodes.new('ShaderNodeTexCoord')
    mp = nt.nodes.new('ShaderNodeMapping')
    mp.inputs['Scale'].default_value = (5.0, 5.0, 5.0)
    nt.links.new(tc.outputs['UV'], mp.inputs['Vector'])

    tex_col = nt.nodes.new('ShaderNodeTexImage')
    tex_col.image = bpy.data.images.load(os.path.join(wood_dir, "Wood094_2K-JPG_Color.jpg"))
    tex_col.interpolation = 'Cubic'
    nt.links.new(mp.outputs['Vector'], tex_col.inputs['Vector'])

    hsv = nt.nodes.new('ShaderNodeHueSaturation')
    hsv.inputs['Hue'].default_value = 0.49
    hsv.inputs['Saturation'].default_value = 0.25
    hsv.inputs['Value'].default_value = 0.055
    nt.links.new(tex_col.outputs['Color'], hsv.inputs['Color'])
    nt.links.new(hsv.outputs['Color'], bsdf.inputs['Base Color'])

    tex_rgh = nt.nodes.new('ShaderNodeTexImage')
    tex_rgh.image = bpy.data.images.load(os.path.join(wood_dir, "Wood094_2K-JPG_Roughness.jpg"))
    tex_rgh.image.colorspace_settings.name = 'Non-Color'
    tex_rgh.interpolation = 'Cubic'
    nt.links.new(mp.outputs['Vector'], tex_rgh.inputs['Vector'])
    rgh_map = nt.nodes.new('ShaderNodeMapRange')
    rgh_map.inputs['From Min'].default_value = 0.0
    rgh_map.inputs['From Max'].default_value = 1.0
    rgh_map.inputs['To Min'].default_value = 0.20
    rgh_map.inputs['To Max'].default_value = 0.38
    nt.links.new(tex_rgh.outputs['Color'], rgh_map.inputs['Value'])
    nt.links.new(rgh_map.outputs['Result'], bsdf.inputs['Roughness'])

    tex_nrm = nt.nodes.new('ShaderNodeTexImage')
    tex_nrm.image = bpy.data.images.load(os.path.join(wood_dir, "Wood094_2K-JPG_NormalGL.jpg"))
    tex_nrm.image.colorspace_settings.name = 'Non-Color'
    tex_nrm.interpolation = 'Cubic'
    nt.links.new(mp.outputs['Vector'], tex_nrm.inputs['Vector'])
    nrm = nt.nodes.new('ShaderNodeNormalMap')
    nrm.inputs['Strength'].default_value = 0.18
    nt.links.new(tex_nrm.outputs['Color'], nrm.inputs['Color'])
    nt.links.new(nrm.outputs['Normal'], bsdf.inputs['Normal'])

    nt.links.new(bsdf.outputs['BSDF'], m_out.inputs['Surface'])

    bpy.ops.mesh.primitive_plane_add(size=4.5 * u, location=(0, 0.5 * u, 0))
    desk = bpy.context.active_object
    desk.name = "StudioDesk"
    desk.data.materials.append(mat_desk)

    # Sculpted luxury dark studio cyclorama backdrop with subtle architectural radial halo
    mat_room = bpy.data.materials.new("DarkStudioBackdrop")
    mat_room.use_nodes = True
    rnt = mat_room.node_tree
    rnt.nodes.clear()
    r_out = rnt.nodes.new('ShaderNodeOutputMaterial')
    r_bsdf = rnt.nodes.new('ShaderNodeBsdfPrincipled')
    r_bsdf.inputs['Roughness'].default_value = 0.94
    r_bsdf.inputs['Specular IOR Level'].default_value = 0.02
    rtc = rnt.nodes.new('ShaderNodeTexCoord')
    rmap = rnt.nodes.new('ShaderNodeMapping')
    rmap.inputs['Location'].default_value = (-0.50, -0.35, 0.0)
    rmap.inputs['Scale'].default_value = (1.5, 2.0, 1.0)
    rnt.links.new(rtc.outputs['UV'], rmap.inputs['Vector'])
    grad = rnt.nodes.new('ShaderNodeTexGradient')
    grad.gradient_type = 'QUADRATIC_SPHERE'
    rnt.links.new(rmap.outputs['Vector'], grad.inputs['Vector'])
    rramp = rnt.nodes.new('ShaderNodeValToRGB')
    rramp.color_ramp.interpolation = 'B_SPLINE'
    e0 = rramp.color_ramp.elements[0]
    e0.position = 0.0; e0.color = (0.010, 0.010, 0.013, 1.0)
    e1 = rramp.color_ramp.elements[1]
    e1.position = 1.0; e1.color = (0.056, 0.052, 0.048, 1.0)
    rnt.links.new(grad.outputs['Fac'], rramp.inputs['Fac'])
    rnt.links.new(rramp.outputs['Color'], r_bsdf.inputs['Base Color'])
    rnt.links.new(r_bsdf.outputs['BSDF'], r_out.inputs['Surface'])

    bpy.ops.mesh.primitive_plane_add(size=7.0 * u, location=(0, 2.8 * u, 1.4 * u), rotation=(math.radians(90), 0, 0))
    wall = bpy.context.active_object
    wall.name = "StudioBackdrop"
    wall.data.materials.append(mat_room)

    def add_area(name, loc, target, energy, size_x, size_y, color=(1.0, 0.98, 0.95), spread_deg=80.0):
        ld = bpy.data.lights.new(name=name, type='AREA')
        ld.shape = 'RECTANGLE'
        ld.size = size_x * u
        ld.size_y = size_y * u
        ld.energy = energy * (u * u)
        ld.color = color
        ld.spread = math.radians(spread_deg)
        lo = bpy.data.objects.new(name, ld)
        bpy.context.collection.objects.link(lo)
        lo.location = tuple(c * u for c in loc)
        direction = mathutils.Vector(tuple(c * u for c in target)) - lo.location
        lo.rotation_euler = direction.to_track_quat('-Z', 'Y').to_euler()
        lo.visible_camera = False
        return lo

    # Ultramock / Apple Pro studio strip lights (raking angles — gleaming chamfers, zero flat blowout!)
    # 1. Overhead-back grazing softbox strip lighting top bevels & subtle brushed gradient on palmrest
    add_area("TopHeroStrip", (-0.10, 0.45, 0.98), (0.0, 0.0, 0.12), energy=top_energy, size_x=1.25, size_y=0.14, color=(1.0, 0.98, 0.95), spread_deg=65.0)
    # 2. Cool-crisp right-side edge kicker illuminating metallic side rails, buttons & rounded corners
    add_area("RightEdgeKicker", (1.05, -0.25, 0.42), (0.0, 0.0, 0.12), energy=rim_energy, size_x=0.18, size_y=0.85, color=(0.88, 0.94, 1.0), spread_deg=60.0)
    # 3. Warm-gold left-back rim light carving dramatic silhouette & chamfer sheen against dark studio
    add_area("LeftWarmRim", (-1.00, 0.35, 0.50), (0.0, 0.0, 0.12), energy=rim_energy * 1.15, size_x=0.22, size_y=0.90, color=(1.0, 0.91, 0.80), spread_deg=60.0)
    # 4. Gentle low front fill so metallic chassis & buttons read with crisp sculpted depth
    add_area("FrontSoftFill", (-0.30, -1.15, 0.26), (0.0, 0.0, 0.10), energy=5.5, size_x=0.80, size_y=0.30, color=(0.95, 0.97, 1.0), spread_deg=80.0)


def upgrade_hardware_materials(objs, exclude_names=(), force_space_black=False, natural_titanium=False):
    """Upgrade USDZ/GLB hardware materials to true CNC anodized aluminum / bead-blasted titanium /
    matte-black keycaps / optical bezel glass (never turning matte black keycaps into mirrors!)."""
    seen = set()
    for o in objs:
        if o.type != 'MESH' or o.name in exclude_names:
            continue
        for mat in o.data.materials:
            if not mat or mat.name in seen or not mat.use_nodes:
                continue
            seen.add(mat.name)
            bsdf = next((n for n in mat.node_tree.nodes if n.type == 'BSDF_PRINCIPLED'), None)
            if not bsdf:
                continue
            bc = bsdf.inputs['Base Color'].default_value
            r, g, b = bc[0], bc[1], bc[2]
            lum = 0.299 * r + 0.587 * g + 0.114 * b
            met = bsdf.inputs['Metallic'].default_value
            rgh = bsdf.inputs['Roughness'].default_value
            bc_linked = bsdf.inputs['Base Color'].is_linked
            met_linked = bsdf.inputs['Metallic'].is_linked
            rgh_linked = bsdf.inputs['Roughness'].is_linked

            # 0. iPhone 18 Pro Max Crimson/Rose -> Sleek Apple Natural / Dark Titanium!
            if natural_titanium and not bc_linked and r > g * 1.25 and r > 0.03:
                if met >= 0.65:
                    # CNC brushed Natural Titanium rail & buttons
                    bsdf.inputs['Base Color'].default_value = (0.44, 0.425, 0.405, 1.0)
                    bsdf.inputs['Metallic'].default_value = 0.95
                    if not rgh_linked:
                        bsdf.inputs['Roughness'].default_value = 0.22
                    if 'Anisotropic' in bsdf.inputs:
                        bsdf.inputs['Anisotropic'].default_value = 0.28
                else:
                    # Antenna bands / trim in subtle matching matte warm-gray titanium tone
                    bsdf.inputs['Base Color'].default_value = (0.24, 0.235, 0.225, 1.0)
                    if not rgh_linked:
                        bsdf.inputs['Roughness'].default_value = 0.42
                continue

            # 1. Pure black optical bezel / camera glass (lum < 0.004) -> Piano-black multi-coated glass
            if not bc_linked and lum < 0.004 and met < 0.35 and rgh > 0.70:
                bsdf.inputs['Base Color'].default_value = (0.004, 0.004, 0.006, 1.0)
                bsdf.inputs['Roughness'].default_value = 0.03
                bsdf.inputs['Coat Weight'].default_value = 0.85
                bsdf.inputs['Coat Roughness'].default_value = 0.02
            # 2. Matte charcoal-black keycaps / rubberized dark plastics (0.004 <= lum < 0.035) -> KEEP MATTE BLACK!
            elif not bc_linked and 0.004 <= lum < 0.035 and met < 0.35 and rgh > 0.50:
                bsdf.inputs['Base Color'].default_value = (0.015, 0.016, 0.019, 1.0)
                bsdf.inputs['Metallic'].default_value = 0.02
                bsdf.inputs['Roughness'].default_value = 0.50
                bsdf.inputs['Specular IOR Level'].default_value = 0.35
                bsdf.inputs['Coat Weight'].default_value = 0.0
            # 3. Chalky USDZ silver aluminum (met < 0.25, mid-high lum) -> Rich brushed Space Silver (or Space Black!)
            elif not met_linked and met < 0.25 and 0.35 <= lum <= 0.90 and rgh >= 0.35:
                if force_space_black:
                    bsdf.inputs['Base Color'].default_value = (0.11, 0.115, 0.125, 1.0)
                    bsdf.inputs['Metallic'].default_value = 0.94
                    bsdf.inputs['Roughness'].default_value = 0.22
                else:
                    if not bc_linked:
                        bsdf.inputs['Base Color'].default_value = (0.46, 0.47, 0.49, 1.0)
                    bsdf.inputs['Metallic'].default_value = 0.92
                    if not rgh_linked:
                        bsdf.inputs['Roughness'].default_value = 0.28
                if 'Anisotropic' in bsdf.inputs:
                    bsdf.inputs['Anisotropic'].default_value = 0.25
            # 4. Already metallic aluminum/titanium -> refine specular response without clipping white!
            elif met >= 0.7:
                if force_space_black and lum > 0.35 and not bc_linked:
                    bsdf.inputs['Base Color'].default_value = (0.11, 0.115, 0.125, 1.0)
                elif not force_space_black and lum > 0.52 and not bc_linked:
                    # Prevent raw 0.80 metallic silver from blowing out white on flat decks
                    scale = 0.48 / max(lum, 1e-4)
                    bsdf.inputs['Base Color'].default_value = (r * scale, g * scale, b * scale, 1.0)
                if not rgh_linked and rgh > 0.32:
                    bsdf.inputs['Roughness'].default_value = 0.24
                if 'Anisotropic' in bsdf.inputs:
                    bsdf.inputs['Anisotropic'].default_value = 0.25
            # 5. Dark anodized trim
            elif not bc_linked and lum < 0.08 and 0.15 <= met <= 0.50:
                bsdf.inputs['Base Color'].default_value = (0.018, 0.019, 0.022, 1.0)
                bsdf.inputs['Roughness'].default_value = 0.38


def make_screen_material(img_path, name="AppScreenMat", glass_sheen=0.042):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    nt = mat.node_tree
    nt.nodes.clear()

    out = nt.nodes.new('ShaderNodeOutputMaterial')
    mix = nt.nodes.new('ShaderNodeMixShader')
    emit = nt.nodes.new('ShaderNodeEmission')
    emit.inputs['Strength'].default_value = 0.99

    gloss = nt.nodes.new('ShaderNodeBsdfGlossy')
    gloss.inputs['Color'].default_value = (1.0, 1.0, 1.0, 1.0)
    gloss.inputs['Roughness'].default_value = 0.018

    lw = nt.nodes.new('ShaderNodeLayerWeight')
    lw.inputs['Blend'].default_value = 0.08
    mul = nt.nodes.new('ShaderNodeMath')
    mul.operation = 'MULTIPLY'
    mul.inputs[1].default_value = glass_sheen
    nt.links.new(lw.outputs['Fresnel'], mul.inputs[0])

    tex = nt.nodes.new('ShaderNodeTexImage')
    img = bpy.data.images.load(img_path)
    img.colorspace_settings.name = 'sRGB'
    tex.image = img
    tex.interpolation = 'Linear'
    tex.extension = 'EXTEND'

    nt.links.new(tex.outputs['Color'], emit.inputs['Color'])
    nt.links.new(mul.outputs['Value'], mix.inputs['Fac'])
    nt.links.new(emit.outputs['Emission'], mix.inputs[1])
    nt.links.new(gloss.outputs['BSDF'], mix.inputs[2])
    nt.links.new(mix.outputs['Shader'], out.inputs['Surface'])
    return mat


def group_imported(before_objs, name):
    new_objs = [o for o in bpy.data.objects if o not in before_objs]
    root = bpy.data.objects.new(name, None)
    bpy.context.collection.objects.link(root)
    for o in new_objs:
        if o.parent is None:
            o.parent = root
    return root, new_objs


def mesh_world_bb(objs):
    bpy.context.view_layer.update()
    pts = []
    for o in objs:
        if o.type != 'MESH' or o.hide_render:
            continue
        for c in o.bound_box:
            pts.append(o.matrix_world @ mathutils.Vector(c))
    xs = [p.x for p in pts]; ys = [p.y for p in pts]; zs = [p.z for p in pts]
    return (min(xs), max(xs)), (min(ys), max(ys)), (min(zs), max(zs))


def rest_on_desk(root, objs, z_offset=0.0):
    (x0, x1), (y0, y1), (z0, z1) = mesh_world_bb(objs)
    root.location.x -= 0.5 * (x0 + x1)
    root.location.y -= 0.5 * (y0 + y1)
    root.location.z -= z0 - z_offset
    bpy.context.view_layer.update()
    return mesh_world_bb(objs)


def add_camera(loc, target, lens_mm=80.0, dof_fstop=None):
    cam_d = bpy.data.cameras.new("Camera")
    cam_d.lens = lens_mm
    cam_d.sensor_width = 36.0
    cam_d.clip_start = 0.01
    cam_d.clip_end = 10000.0
    cam = bpy.data.objects.new("Camera", cam_d)
    bpy.context.collection.objects.link(cam)
    cam.location = mathutils.Vector(loc)
    tgt = mathutils.Vector(target)
    direction = tgt - cam.location
    cam.rotation_euler = direction.to_track_quat('-Z', 'Y').to_euler()
    if dof_fstop is not None:
        cam_d.dof.use_dof = True
        cam_d.dof.focus_distance = direction.length
        cam_d.dof.aperture_fstop = dof_fstop
    bpy.context.scene.camera = cam
    return cam


def isolate_iphone18_promax(objs):
    """iphone-18-pro.usdz contains both iPhone 18 Pro Max (EHjrGDHNHzgNjtE) and iPhone 18 Pro (.001)
    side-by-side; keep only the Pro Max subtree so a single hero phone renders cleanly."""
    scr_keep = bpy.data.objects["EHjrGDHNHzgNjtE"]
    scr_drop = bpy.data.objects.get("EHjrGDHNHzgNjtE.001")
    if scr_drop is None:
        return objs
    bpy.context.view_layer.update()

    def chain(o):
        c = []
        while o is not None:
            c.append(o)
            o = o.parent
        return list(reversed(c))

    ck = chain(scr_keep)
    cd = chain(scr_drop)
    branch_keep = None
    for a, b in zip(ck, cd):
        if a != b:
            branch_keep = a
            break
    if branch_keep is not None:
        kept = []
        for o in objs:
            if branch_keep in chain(o):
                kept.append(o)
            elif o.type == 'MESH':
                o.hide_render = True
                o.hide_viewport = True
        return kept
    return objs


def render_device(device, lang, opts):
    sc = reset_scene(opts["width"], opts["height"], opts["samples"])
    models_dir = opts["models_dir"]
    screen_img = os.path.join(opts["screens_dir"], f"{device}-{lang}.png")
    out_png = os.path.join(opts["out_dir"], f"{device}-{lang}.png")

    is_cm = device in ("duo", "desk", "web")
    hdri_rot = {"duo": 48.0, "android": 62.0, "desk": 26.0, "web": 40.0}.get(device, 35.0)
    top_e = {"duo": 18.0, "android": 18.0, "desk": 11.0, "web": 16.0}.get(device, 15.0)
    rim_e = {"duo": 28.0, "android": 30.0, "desk": 22.0, "web": 24.0}.get(device, 24.0)
    build_studio(models_dir, scale_cm=is_cm, hdri_rot_deg=hdri_rot, top_energy=top_e, rim_energy=rim_e)
    before = set(bpy.data.objects)

    if device == "duo":
        # Apple official iPhone 18 Pro Max USDZ — Natural Titanium hero 3/4 stance on dark obsidian plinth!
        bpy.ops.wm.usd_import(filepath=os.path.join(models_dir, "iphone-18-pro.usdz"))
        root, objs = group_imported(before, "iPhone18ProMax")
        kept = isolate_iphone18_promax(objs)
        upgrade_hardware_materials(kept, exclude_names=("EHjrGDHNHzgNjtE",), natural_titanium=True)
        scr = bpy.data.objects["EHjrGDHNHzgNjtE"]
        scr.data.materials.clear()
        scr.data.materials.append(make_screen_material(screen_img, "iPhoneScreen"))
        # Standing hero-angled (tilted 8 deg back, 15 deg yaw showing CNC titanium rail + side buttons!)
        root.rotation_euler = (math.radians(-8.0), 0.0, math.radians(-15.0))
        (x0, x1), (y0, y1), (z0, z1) = rest_on_desk(root, kept, z_offset=0.45)
        cx, cy, cz = 0.5*(x0+x1), 0.5*(y0+y1), 0.5*(z0+z1)
        add_camera((cx - 1.2, cy - 58.0, cz + 2.8), (cx, cy, cz - 0.15), lens_mm=85.0, dof_fstop=None)

    elif device == "android":
        # Samsung official Galaxy S25+ Navy (large concentric rounded corners!) — hero 3/4 stance on dark obsidian plinth!
        bpy.ops.import_scene.gltf(filepath=os.path.join(models_dir, "galaxy-s25-plus.glb"))
        root, objs = group_imported(before, "GalaxyS25Plus")
        upgrade_hardware_materials(objs, exclude_names=("Display_ActiveArea",))
        scr = bpy.data.objects["Display_ActiveArea"]
        scr.data.materials.clear()
        scr.data.materials.append(make_screen_material(screen_img, "AndroidScreen"))
        # Standing hero-angled (tilted 8 deg back, +15 deg yaw showing metallic navy aluminum frame + buttons!)
        root.rotation_euler = (math.radians(-8.0), 0.0, math.radians(15.0))
        (x0, x1), (y0, y1), (z0, z1) = rest_on_desk(root, objs, z_offset=0.0045)
        cx, cy, cz = 0.5*(x0+x1), 0.5*(y0+y1), 0.5*(z0+z1)
        add_camera((cx + 0.012, cy - 0.575, cz + 0.028), (cx, cy, cz - 0.0015), lens_mm=85.0, dof_fstop=None)

    elif device == "desk":
        # Ultra-thin 11.5mm Apple MacBook Air 15" Silver — rich Space Silver aluminum + matte black keycaps!
        bpy.ops.wm.usd_import(filepath=os.path.join(models_dir, "macbook-air-15-silver.usdz"))
        root, objs = group_imported(before, "MacBookAir15")
        for o in objs:
            if o.type == 'MESH' and len(o.data.polygons) <= 24:
                bb = [o.matrix_world @ mathutils.Vector(c) for c in o.bound_box]
                if max(p.x for p in bb) - min(p.x for p in bb) > 33.5 and max(p.z for p in bb) - min(p.z for p in bb) > 20.0:
                    o.hide_render = True
                    o.hide_viewport = True
        upgrade_hardware_materials(objs, exclude_names=("OQzaQDtbMVhhlAr",))
        scr = bpy.data.objects["OQzaQDtbMVhhlAr"]
        scr.data.materials.clear()
        scr.data.materials.append(make_screen_material(screen_img, "MacBookAirScreen"))
        root.rotation_euler = (0.0, 0.0, math.radians(-8.5))
        (x0, x1), (y0, y1), (z0, z1) = rest_on_desk(root, objs)
        cx, cy, cz = 0.5*(x0+x1), 0.5*(y0+y1), 0.5*(z0+z1)
        add_camera((cx - 7.2, cy - 92.5, cz + 12.2), (cx + 0.2, cy + 1.0, cz - 0.6), lens_mm=74.0, dof_fstop=None)

    elif device == "web":
        # 27" 4K Workstation Display running Windows 11 + Edge/Chrome app.monoid.build!
        bpy.ops.wm.usd_import(filepath=os.path.join(models_dir, "studio-display.usdz"))
        root, objs = group_imported(before, "Windows4KDisplay")
        for o in objs:
            if o.type == 'MESH' and len(o.data.polygons) <= 24:
                bb = [o.matrix_world @ mathutils.Vector(c) for c in o.bound_box]
                if max(p.x for p in bb) - min(p.x for p in bb) > 61.5:
                    o.hide_render = True
                    o.hide_viewport = True
        upgrade_hardware_materials(objs, exclude_names=("IZJsAfohLAwOHok",), force_space_black=True)
        scr = bpy.data.objects["IZJsAfohLAwOHok"]
        scr.data.materials.clear()
        scr.data.materials.append(make_screen_material(screen_img, "WindowsDisplayScreen"))
        root.rotation_euler = (0.0, 0.0, math.radians(-7.5))
        (x0, x1), (y0, y1), (z0, z1) = rest_on_desk(root, objs)
        cx, cy, cz = 0.5*(x0+x1), 0.5*(y0+y1), 0.5*(z0+z1)
        add_camera((cx - 8.5, cy - 157.0, cz + 5.6), (cx, cy, cz - 0.8), lens_mm=74.0, dof_fstop=None)

    os.makedirs(opts["out_dir"], exist_ok=True)
    sc.render.filepath = out_png
    bpy.ops.render.render(write_still=True)
    print(f"RENDERED {out_png}")


def main():
    opts = parse_args()
    for dev in opts["devices"]:
        for lang in opts["langs"]:
            render_device(dev, lang, opts)


if __name__ == "__main__":
    main()
