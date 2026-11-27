#!/usr/bin/env python3
"""
Render razor-sharp 2000x1500 studio product photography for monoid.build #devices
using official manufacturer 3D CAD models + CC0 oak/walnut PBR + golden-hour lighting:
  - duo:     Apple official iPhone Duo USDZ (Pose="Landscape", gently folded 164 deg open book)
  - android: Samsung official Galaxy S25 Ultra GLB (resting naturally on CNC aluminum desk dock)
  - desk:    Apple official MacBook Air 15" Silver USDZ (ultra-thin 11.5mm unibody)
  - web:     Apple official Studio Display USDZ (5K display with macOS desktop + Safari window)

Optical & material engineering:
  - Upgrades RealityKit/USDZ chalky metallic=0 aluminum & roughness=1 bezels into true
    CNC anodized aluminum (Metallic=0.92, Roughness=0.22) and optical glass bezels (Roughness=0.03).
  - Separates the noise-free `Emit` pass BEFORE OpenImageDenoise (`Denoise(Combined - Emit) + Emit`)
    with `BLACKMAN_HARRIS` (width=1.0) and `Standard` view transform so 8pt UI typography stays
    100% crisp and warm-paper true-color (#F4F2EE vs #F5F3EF), zero OIDN smearing.
  - Golden-hour directional sun through architectural window-frame gobo + rich satin wood reflection
    + deep warm architectural room bokeh (shallow f/2.4 DoF focused on the display plane).
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
        "width": 2000,
        "height": 1500,
        "samples": 48,
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


def reset_scene(w, h, samples):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    sc = bpy.context.scene
    sc.render.engine = 'CYCLES'
    sc.cycles.device = 'CPU'
    sc.cycles.samples = samples
    sc.cycles.use_adaptive_sampling = True
    sc.cycles.adaptive_threshold = 0.014
    sc.cycles.use_denoising = False  # Handled in Compositor AFTER separating Emit!
    sc.cycles.max_bounces = 8
    sc.cycles.diffuse_bounces = 4
    sc.cycles.glossy_bounces = 4
    sc.cycles.transmission_bounces = 6
    sc.cycles.transparent_max_bounces = 8
    sc.cycles.sample_clamp_indirect = 3.5
    sc.cycles.pixel_filter_type = 'BLACKMAN_HARRIS'
    sc.cycles.filter_width = 1.0

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

    # Zero-blur Compositor: Denoise(Combined - Emit) + Emit
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

    add = nt.nodes.new('CompositorNodeMixRGB')
    add.blend_type = 'ADD'
    add.inputs['Fac'].default_value = 1.0

    comp = nt.nodes.new('CompositorNodeComposite')

    nt.links.new(rl.outputs['Image'], sub.inputs[1])
    nt.links.new(rl.outputs['Emit'], sub.inputs[2])
    nt.links.new(sub.outputs['Image'], den.inputs['Image'])
    nt.links.new(rl.outputs['Denoising Normal'], den.inputs['Normal'])
    nt.links.new(rl.outputs['Denoising Albedo'], den.inputs['Albedo'])
    nt.links.new(den.outputs['Image'], add.inputs[1])
    nt.links.new(rl.outputs['Emit'], add.inputs[2])
    nt.links.new(add.outputs['Image'], comp.inputs['Image'])

    return sc


def build_studio(models_dir, scale_cm=True):
    """Build golden-hour architectural studio inspired by Comma duo-open.webp:
    rich satin walnut/oak tabletop with diagonal window sunlight + deep warm architectural bokeh."""
    u = 100.0 if scale_cm else 1.0

    # World: dark warm ambient studio interior so metallic highlights & golden sun pop naturally
    world = bpy.data.worlds.new("StudioWorld")
    bpy.context.scene.world = world
    world.use_nodes = True
    wn = world.node_tree.nodes
    wl = world.node_tree.links
    wn.clear()
    out = wn.new('ShaderNodeOutputWorld')
    bg = wn.new('ShaderNodeBackground')
    bg.inputs['Color'].default_value = (0.34, 0.30, 0.26, 1.0)
    bg.inputs['Strength'].default_value = 0.32
    wl.new(bg.outputs['Background'], out.inputs['Surface'])

    # Rich satin warm walnut-oak tabletop (Wood094_2K-JPG) with realistic subtle screen reflection!
    wood_dir = os.path.join(models_dir, "wood")
    mat_desk = bpy.data.materials.new("RealWalnutOakDesk")
    mat_desk.use_nodes = True
    nt = mat_desk.node_tree
    nt.nodes.clear()
    m_out = nt.nodes.new('ShaderNodeOutputMaterial')
    bsdf = nt.nodes.new('ShaderNodeBsdfPrincipled')
    bsdf.inputs['IOR'].default_value = 1.50
    bsdf.inputs['Specular IOR Level'].default_value = 0.42
    bsdf.inputs['Coat Weight'].default_value = 0.30
    bsdf.inputs['Coat Roughness'].default_value = 0.14

    tc = nt.nodes.new('ShaderNodeTexCoord')
    mp = nt.nodes.new('ShaderNodeMapping')
    mp.inputs['Scale'].default_value = (5.2, 5.2, 5.2)
    nt.links.new(tc.outputs['UV'], mp.inputs['Vector'])

    tex_col = nt.nodes.new('ShaderNodeTexImage')
    tex_col.image = bpy.data.images.load(os.path.join(wood_dir, "Wood094_2K-JPG_Color.jpg"))
    tex_col.interpolation = 'Cubic'
    nt.links.new(mp.outputs['Vector'], tex_col.inputs['Vector'])

    # Deep warm architectural oak-walnut tone (matches Comma duo-open.webp warmth & contrast)
    hsv = nt.nodes.new('ShaderNodeHueSaturation')
    hsv.inputs['Hue'].default_value = 0.495
    hsv.inputs['Saturation'].default_value = 0.94
    hsv.inputs['Value'].default_value = 0.42
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
    rgh_map.inputs['To Min'].default_value = 0.22
    rgh_map.inputs['To Max'].default_value = 0.46
    nt.links.new(tex_rgh.outputs['Color'], rgh_map.inputs['Value'])
    nt.links.new(rgh_map.outputs['Result'], bsdf.inputs['Roughness'])

    tex_nrm = nt.nodes.new('ShaderNodeTexImage')
    tex_nrm.image = bpy.data.images.load(os.path.join(wood_dir, "Wood094_2K-JPG_NormalGL.jpg"))
    tex_nrm.image.colorspace_settings.name = 'Non-Color'
    tex_nrm.interpolation = 'Cubic'
    nt.links.new(mp.outputs['Vector'], tex_nrm.inputs['Vector'])
    nrm = nt.nodes.new('ShaderNodeNormalMap')
    nrm.inputs['Strength'].default_value = 0.42
    nt.links.new(tex_nrm.outputs['Color'], nrm.inputs['Color'])
    nt.links.new(nrm.outputs['Normal'], bsdf.inputs['Normal'])

    nt.links.new(bsdf.outputs['BSDF'], m_out.inputs['Surface'])

    bpy.ops.mesh.primitive_plane_add(size=3.6 * u, location=(0, 0.55 * u, 0))
    desk = bpy.context.active_object
    desk.name = "StudioDesk"
    desk.data.materials.append(mat_desk)

    # Dreamy feathered architectural bokeh backdrop (smooth B-spline sunlit gradient, ZERO hard wall edges!)
    mat_room = bpy.data.materials.new("StudioBackdrop")
    mat_room.use_nodes = True
    rnt = mat_room.node_tree
    rnt.nodes.clear()
    r_out = rnt.nodes.new('ShaderNodeOutputMaterial')
    r_bsdf = rnt.nodes.new('ShaderNodeBsdfPrincipled')
    r_bsdf.inputs['Roughness'].default_value = 0.98
    r_bsdf.inputs['Specular IOR Level'].default_value = 0.0
    rtc = rnt.nodes.new('ShaderNodeTexCoord')
    rsep = rnt.nodes.new('ShaderNodeSeparateXYZ')
    rnt.links.new(rtc.outputs['UV'], rsep.inputs['Vector'])
    rramp = rnt.nodes.new('ShaderNodeValToRGB')
    rramp.color_ramp.interpolation = 'B_SPLINE'
    e0 = rramp.color_ramp.elements[0]
    e0.position = 0.00; e0.color = (0.12, 0.085, 0.058, 1.0)
    e1 = rramp.color_ramp.elements[1]
    e1.position = 0.36; e1.color = (0.20, 0.14, 0.095, 1.0)
    e2 = rramp.color_ramp.elements.new(0.56)
    e2.color = (0.10, 0.072, 0.050, 1.0)
    e3 = rramp.color_ramp.elements.new(0.67)
    e3.color = (0.22, 0.16, 0.11, 1.0)
    e4 = rramp.color_ramp.elements.new(0.75)
    e4.color = (0.76, 0.65, 0.50, 1.0)
    e5 = rramp.color_ramp.elements.new(0.84)
    e5.color = (0.24, 0.17, 0.12, 1.0)
    e6 = rramp.color_ramp.elements.new(1.00)
    e6.color = (0.12, 0.085, 0.058, 1.0)
    rnt.links.new(rsep.outputs['X'], rramp.inputs['Fac'])
    rnt.links.new(rramp.outputs['Color'], r_bsdf.inputs['Base Color'])
    rnt.links.new(r_bsdf.outputs['BSDF'], r_out.inputs['Surface'])

    bpy.ops.mesh.primitive_plane_add(size=7.0 * u, location=(0, 3.0 * u, 1.4 * u), rotation=(math.radians(90), 0, 0))
    wall = bpy.context.active_object
    wall.name = "StudioBackdrop"
    wall.data.materials.append(mat_room)

    # Golden-hour directional SUN light from upper-left-front casting crisp-soft diagonal sunlit beam on desk!
    sun_d = bpy.data.lights.new("GoldenSun", type='SUN')
    sun_d.energy = 4.2
    sun_d.angle = math.radians(3.5)
    sun_d.color = (1.0, 0.91, 0.78)
    sun = bpy.data.objects.new("GoldenSun", sun_d)
    bpy.context.collection.objects.link(sun)
    sun.rotation_euler = (math.radians(54), math.radians(12), math.radians(-56))

    # Off-camera window frame gobo casting diagonal sunlit stripe + soft shadow on foreground oak desk (like Comma duo-open.webp!)
    bpy.ops.mesh.primitive_cube_add(size=1.0 * u, location=(-0.38 * u, -0.32 * u, 0.28 * u))
    gobo = bpy.context.active_object
    gobo.scale = (0.045, 2.2, 0.06)
    gobo.rotation_euler = (0, 0, math.radians(-18))
    gobo.visible_camera = False
    gobo.visible_glossy = False
    gobo.visible_diffuse = False
    gobo.name = "WindowMullionGobo"

    bpy.ops.mesh.primitive_cube_add(size=1.0 * u, location=(-0.22 * u, 0.35 * u, 0.48 * u))
    gobo2 = bpy.context.active_object
    gobo2.scale = (0.65, 2.2, 0.04)
    gobo2.rotation_euler = (0, 0, math.radians(-18))
    gobo2.visible_camera = False
    gobo2.visible_glossy = False
    gobo2.visible_diffuse = False
    gobo2.name = "WindowTopShade"

    def add_area(name, loc, target, energy, size_x, size_y, color=(1.0, 0.96, 0.90)):
        ld = bpy.data.lights.new(name=name, type='AREA')
        ld.shape = 'RECTANGLE'
        ld.size = size_x * u
        ld.size_y = size_y * u
        ld.energy = energy * (u * u)
        ld.color = color
        lo = bpy.data.objects.new(name, ld)
        bpy.context.collection.objects.link(lo)
        lo.location = tuple(c * u for c in loc)
        direction = mathutils.Vector(tuple(c * u for c in target)) - lo.location
        lo.rotation_euler = direction.to_track_quat('-Z', 'Y').to_euler()
        lo.visible_camera = False
        return lo

    # Soft cool-neutral sky fill from right-front so CNC silver aluminum bevels & dark titanium edges gleam crisply
    add_area("SkyFill", (1.1, -0.75, 0.65), (0.0, 0.0, 0.12), energy=12.0, size_x=0.95, size_y=0.65, color=(0.90, 0.94, 1.0))
    # Crisp overhead specular strip (catches fine silver chamfer highlight along top bezel edge — like Apple studio shots!)
    add_area("TopRimStrip", (-0.15, 0.18, 0.75), (0.0, 0.0, 0.08), energy=14.0, size_x=1.2, size_y=0.14, color=(1.0, 0.98, 0.95))
    # Gentle front-left bounce so front keyboard & lower lip never go muddy black
    add_area("FrontBounce", (-0.60, -0.85, 0.35), (0.0, 0.0, 0.08), energy=5.5, size_x=0.80, size_y=0.50, color=(1.0, 0.95, 0.88))


def upgrade_hardware_materials(objs, exclude_names=()):
    """Fix RealityKit/USDZ chalky metallic=0 aluminum & roughness=1 black glass bezels."""
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
            lum = 0.299 * bc[0] + 0.587 * bc[1] + 0.114 * bc[2]
            met = bsdf.inputs['Metallic'].default_value
            rgh = bsdf.inputs['Roughness'].default_value
            bc_linked = bsdf.inputs['Base Color'].is_linked
            met_linked = bsdf.inputs['Metallic'].is_linked
            rgh_linked = bsdf.inputs['Roughness'].is_linked

            # 1. Pure black chalk bezel (rgh >= 0.8, lum < 0.03) -> Glossy optical display glass!
            if not bc_linked and lum < 0.035 and met < 0.3 and rgh > 0.75:
                bsdf.inputs['Base Color'].default_value = (0.008, 0.008, 0.010, 1.0)
                bsdf.inputs['Roughness'].default_value = 0.04
                bsdf.inputs['Coat Weight'].default_value = 0.85
                bsdf.inputs['Coat Roughness'].default_value = 0.02
            # 2. Chalky silver aluminum (mid-light gray with met == 0) -> True CNC anodized silver aluminum!
            elif not met_linked and met < 0.2 and 0.40 <= lum <= 0.88 and rgh >= 0.45:
                if not bc_linked:
                    bsdf.inputs['Base Color'].default_value = (0.64, 0.65, 0.67, 1.0)
                bsdf.inputs['Metallic'].default_value = 0.92
                if not rgh_linked:
                    bsdf.inputs['Roughness'].default_value = 0.24
            # 3. Already metallic aluminum with high default roughness -> refine brushed sheen
            elif met >= 0.8 and not rgh_linked and rgh > 0.40:
                bsdf.inputs['Roughness'].default_value = 0.23
            # 4. Dark keycaps / charcoal matte trim -> clean satin anodized feel
            elif not bc_linked and lum < 0.06 and 0.15 <= met <= 0.35:
                bsdf.inputs['Base Color'].default_value = (0.022, 0.023, 0.025, 1.0)
                bsdf.inputs['Roughness'].default_value = 0.42


def fold_duo_open_book(objs, half_angle_deg=9.0, hinge_half_w=0.45):
    """Gently fold flat unfolded iPhone Duo (X in [-8.3, 8.3]) into a realistic open-book V-shape
    around the center hinge X=0 so it stands stably like Comma's duo-open.webp!"""
    bpy.context.view_layer.update()
    ang = math.radians(half_angle_deg)
    for o in objs:
        if o.type != 'MESH' or o.hide_render:
            continue
        mw = o.matrix_world.copy()
        mi = mw.inverted()
        mesh = o.data
        for v in mesh.vertices:
            wp = mw @ v.co
            x, y, z = wp.x, wp.y, wp.z
            ax = abs(x)
            sgn = 1.0 if x >= 0.0 else -1.0
            if ax <= hinge_half_w:
                # Smooth C1 quadratic bend across the center flexible hinge
                t = ax / hinge_half_w
                theta = ang * (0.5 * t)
                nx = x
                ny = y - (0.5 * hinge_half_w * math.sin(ang) * t * t)
            else:
                dx = ax - hinge_half_w
                base_y = -0.5 * hinge_half_w * math.sin(ang)
                nx = sgn * (hinge_half_w + dx * math.cos(ang))
                ny = y + base_y - dx * math.sin(ang)
            v.co = mi @ mathutils.Vector((nx, ny, z))
        mesh.update()


def make_phone_dock(u=1.0):
    """Minimal CNC-machined dark anodized aluminum desktop dock/stand so Galaxy S25 Ultra
    rests naturally with real physical gravity & contact shadow (never balancing on its thin rim)."""
    mat_dock = bpy.data.materials.new("AnodizedDock")
    mat_dock.use_nodes = True
    bsdf = mat_dock.node_tree.nodes.get("Principled BSDF")
    bsdf.inputs['Base Color'].default_value = (0.14, 0.14, 0.15, 1.0)
    bsdf.inputs['Metallic'].default_value = 0.88
    bsdf.inputs['Roughness'].default_value = 0.28

    parts = []
    # Sleek beveled base plate resting flat on desk (Z=0..0.005m)
    bpy.ops.mesh.primitive_cube_add(size=1.0, location=(0, 0.022 * u, 0.0025 * u))
    base = bpy.context.active_object
    base.scale = (0.068 * u, 0.072 * u, 0.005 * u)
    bpy.ops.object.transform_apply(scale=True)
    bev = base.modifiers.new("Bevel", 'BEVEL')
    bev.width = 0.0018 * u; bev.segments = 3
    base.data.materials.append(mat_dock)
    parts.append(base)

    # Angled rear backrest arm supporting the back of the phone (tilted 14 deg)
    bpy.ops.mesh.primitive_cube_add(size=1.0, location=(0, 0.026 * u, 0.048 * u), rotation=(math.radians(-14.0), 0, 0))
    back = bpy.context.active_object
    back.scale = (0.056 * u, 0.0045 * u, 0.092 * u)
    bpy.ops.object.transform_apply(scale=True)
    bev2 = back.modifiers.new("Bevel", 'BEVEL')
    bev2.width = 0.0015 * u; bev2.segments = 3
    back.data.materials.append(mat_dock)
    parts.append(back)

    # Minimal front cradle lip catching the phone's bottom edge
    bpy.ops.mesh.primitive_cube_add(size=1.0, location=(0, -0.011 * u, 0.006 * u))
    lip = bpy.context.active_object
    lip.scale = (0.058 * u, 0.007 * u, 0.006 * u)
    bpy.ops.object.transform_apply(scale=True)
    bev3 = lip.modifiers.new("Bevel", 'BEVEL')
    bev3.width = 0.0015 * u; bev3.segments = 3
    lip.data.materials.append(mat_dock)
    parts.append(lip)

    dock_root = bpy.data.objects.new("PhoneDock", None)
    bpy.context.collection.objects.link(dock_root)
    for p in parts:
        p.parent = dock_root
    return dock_root, parts


def make_screen_material(img_path, name="AppScreenMat", glass_sheen=0.045):
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
    gloss.inputs['Roughness'].default_value = 0.025

    lw = nt.nodes.new('ShaderNodeLayerWeight')
    lw.inputs['Blend'].default_value = 0.09
    mul = nt.nodes.new('ShaderNodeMath')
    mul.operation = 'MULTIPLY'
    mul.inputs[1].default_value = glass_sheen
    nt.links.new(lw.outputs['Fresnel'], mul.inputs[0])

    tex = nt.nodes.new('ShaderNodeTexImage')
    img = bpy.data.images.load(img_path)
    img.colorspace_settings.name = 'sRGB'
    tex.image = img
    tex.interpolation = 'Cubic'
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


def hide_objs(objs, names):
    for o in objs:
        if o.name in names:
            o.hide_render = True
            o.hide_viewport = True


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


def add_camera(loc, target, lens_mm=80.0, dof_fstop=2.4):
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


def render_device(device, lang, opts):
    sc = reset_scene(opts["width"], opts["height"], opts["samples"])
    models_dir = opts["models_dir"]
    screen_img = os.path.join(opts["screens_dir"], f"{device}-{lang}.png")
    out_png = os.path.join(opts["out_dir"], f"{device}-{lang}.png")

    is_cm = device in ("duo", "desk", "web")
    build_studio(models_dir, scale_cm=is_cm)
    before = set(bpy.data.objects)

    if device == "duo":
        bpy.ops.wm.usd_import(filepath=os.path.join(models_dir, "iphone-duo-open.usda"))
        root, objs = group_imported(before, "iPhoneDuo")
        hide_objs(objs, {"lJPfQMFXvvcmdtA"})
        # Real 162-deg open-book V-fold so it stands stably on sunlit wood just like Comma duo-open.webp!
        fold_duo_open_book(objs, half_angle_deg=9.0, hinge_half_w=0.45)
        upgrade_hardware_materials(objs, exclude_names=("UXtsBZYlaUvHoEh",))
        scr = bpy.data.objects["UXtsBZYlaUvHoEh"]
        scr.data.materials.clear()
        scr.data.materials.append(make_screen_material(screen_img, "DuoScreen"))
        # Subtle editorial yaw so both wings & center V-fold gleam clearly
        root.rotation_euler = (0.0, 0.0, math.radians(-6.5))
        (x0, x1), (y0, y1), (z0, z1) = rest_on_desk(root, objs)
        cx, cy, cz = 0.5*(x0+x1), 0.5*(y0+y1), 0.5*(z0+z1)
        # Generous sunlit wood & bokeh framing (matching Comma duo-open.webp proportions) with tack-sharp f/5.6 screen!
        add_camera((cx - 1.4, cy - 47.5, cz + 3.2), (cx, cy, cz - 0.6), lens_mm=78.0, dof_fstop=5.6)

    elif device == "android":
        bpy.ops.import_scene.gltf(filepath=os.path.join(models_dir, "galaxy-s25-ultra.glb"))
        root, objs = group_imported(before, "GalaxyS25Ultra")
        upgrade_hardware_materials(objs, exclude_names=("Display_ActiveArea",))
        scr = bpy.data.objects["Display_ActiveArea"]
        scr.data.materials.clear()
        scr.data.materials.append(make_screen_material(screen_img, "AndroidScreen"))
        # Place phone resting naturally on CNC dark-anodized desk dock (11 deg tilt, 10 deg yaw)
        dock_root, dock_parts = make_phone_dock(u=1.0)
        root.rotation_euler = (math.radians(-11.0), 0.0, 0.0)
        rest_on_desk(root, objs, z_offset=0.0055)
        # Group phone + dock together and give subtle studio yaw
        rig = bpy.data.objects.new("AndroidRig", None)
        bpy.context.collection.objects.link(rig)
        root.parent = rig
        dock_root.parent = rig
        rig.rotation_euler = (0.0, 0.0, math.radians(-10.0))
        # Focus directly on the screen plane with deep f/11 so 100% of the tilted display is tack-sharp while backdrop stays soft!
        (sx0, sx1), (sy0, sy1), (sz0, sz1) = mesh_world_bb([scr])
        scx, scy, scz = 0.5*(sx0+sx1), 0.5*(sy0+sy1), 0.5*(sz0+sz1)
        add_camera((scx - 0.028, scy - 0.56, scz + 0.036), (scx, scy, scz - 0.004), lens_mm=76.0, dof_fstop=11.0)

    elif device == "desk":
        # Ultra-thin 11.5mm Apple MacBook Air 15" Silver!
        bpy.ops.wm.usd_import(filepath=os.path.join(models_dir, "macbook-air-15-silver.usdz"))
        root, objs = group_imported(before, "MacBookAir15")
        # Hide any AR proxy box if present
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
        root.rotation_euler = (0.0, 0.0, math.radians(-9.5))
        (x0, x1), (y0, y1), (z0, z1) = rest_on_desk(root, objs)
        cx, cy, cz = 0.5*(x0+x1), 0.5*(y0+y1), 0.5*(z0+z1)
        # Sleek editorial camera showing razor-thin 11.5mm MacBook Air profile with clean breathing room + tack-sharp f/8 screen!
        add_camera((cx - 7.5, cy - 92.0, cz + 12.2), (cx + 0.2, cy + 1.0, cz - 0.8), lens_mm=72.0, dof_fstop=8.0)

    elif device == "web":
        bpy.ops.wm.usd_import(filepath=os.path.join(models_dir, "studio-display.usdz"))
        root, objs = group_imported(before, "StudioDisplay")
        for o in objs:
            if o.type == 'MESH' and len(o.data.polygons) <= 24:
                bb = [o.matrix_world @ mathutils.Vector(c) for c in o.bound_box]
                if max(p.x for p in bb) - min(p.x for p in bb) > 61.5:
                    o.hide_render = True
                    o.hide_viewport = True
        upgrade_hardware_materials(objs, exclude_names=("IZJsAfohLAwOHok",))
        scr = bpy.data.objects["IZJsAfohLAwOHok"]
        scr.data.materials.clear()
        scr.data.materials.append(make_screen_material(screen_img, "StudioDisplayScreen"))
        root.rotation_euler = (0.0, 0.0, math.radians(-8.5))
        (x0, x1), (y0, y1), (z0, z1) = rest_on_desk(root, objs)
        cx, cy, cz = 0.5*(x0+x1), 0.5*(y0+y1), 0.5*(z0+z1)
        add_camera((cx - 9.5, cy - 158.0, cz + 5.8), (cx, cy, cz - 1.2), lens_mm=72.0, dof_fstop=8.0)

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
