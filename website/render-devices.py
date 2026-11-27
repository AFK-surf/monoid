#!/usr/bin/env python3
"""
Render razor-sharp 2000x1500 studio product shots for monoid.build #devices
using official manufacturer 3D CAD models (Apple USDZ + Samsung GLB) + CC0 oak PBR.

Key optical technique for zero-blur UI legibility:
  - Cycles renders with `use_denoising = False` + `BLACKMAN_HARRIS` (width=1.0)
  - `view_layer.use_pass_emit = True` + `use_pass_denoising_data = True`
  - Compositor subtracts the noise-free `Emit` pass (the UI display) BEFORE running
    OpenImageDenoise on `Combined - Emit` (wood grain, shadows, brushed aluminum),
    then adds `Emit` back cleanly — 100% crisp 8pt typography, zero OIDN smearing!
  - Uses `Standard` view transform so screen `#F5F3EF` stays true warm paper (no AgX gray cast).
"""

import bpy
import math
import mathutils
import os
import sys


def parse_args():
    argv = sys.argv
    if "--" in argv:
        argv = argv[argv.index("--") + 1:]
    else:
        argv = []
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
    sc.cycles.adaptive_threshold = 0.015
    sc.cycles.use_denoising = False  # Handled in Compositor AFTER separating Emit!
    sc.cycles.max_bounces = 8
    sc.cycles.diffuse_bounces = 4
    sc.cycles.glossy_bounces = 4
    sc.cycles.transmission_bounces = 6
    sc.cycles.transparent_max_bounces = 8
    sc.cycles.sample_clamp_indirect = 4.0
    sc.cycles.pixel_filter_type = 'BLACKMAN_HARRIS'
    sc.cycles.filter_width = 1.0

    sc.render.resolution_x = w
    sc.render.resolution_y = h
    sc.render.resolution_percentage = 100
    sc.render.image_settings.file_format = 'PNG'
    sc.render.image_settings.color_mode = 'RGB'
    sc.render.image_settings.color_depth = '8'

    # True-color Standard transform so #F5F3EF UI paper renders exact #F5F3EF (never AgX gray!)
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
    rl.location = (-500, 0)

    sub = nt.nodes.new('CompositorNodeMixRGB')
    sub.blend_type = 'SUBTRACT'
    sub.inputs['Fac'].default_value = 1.0
    sub.location = (-220, 120)

    den = nt.nodes.new('CompositorNodeDenoise')
    den.prefilter = 'ACCURATE'
    den.use_hdr = True
    den.location = (40, 120)

    add = nt.nodes.new('CompositorNodeMixRGB')
    add.blend_type = 'ADD'
    add.inputs['Fac'].default_value = 1.0
    add.location = (300, 40)

    comp = nt.nodes.new('CompositorNodeComposite')
    comp.location = (560, 40)

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
    """Build warm sunlit architectural studio with real CC0 Wood094 PBR oak desk."""
    u = 100.0 if scale_cm else 1.0  # 1m = 100cm in Apple USDZ space

    # World: soft warm daylight studio (balanced so wall and aluminum never blow out under Standard)
    world = bpy.data.worlds.new("StudioWorld")
    bpy.context.scene.world = world
    world.use_nodes = True
    wn = world.node_tree.nodes
    wl = world.node_tree.links
    wn.clear()
    out = wn.new('ShaderNodeOutputWorld')
    bg = wn.new('ShaderNodeBackground')
    bg.inputs['Color'].default_value = (0.72, 0.69, 0.64, 1.0)
    bg.inputs['Strength'].default_value = 0.28
    wl.new(bg.outputs['Background'], out.inputs['Surface'])

    # Real CC0 Oak Wood Desk Material (Wood094_2K-JPG)
    wood_dir = os.path.join(models_dir, "wood")
    mat_desk = bpy.data.materials.new("RealOakDesk")
    mat_desk.use_nodes = True
    nt = mat_desk.node_tree
    nt.nodes.clear()
    m_out = nt.nodes.new('ShaderNodeOutputMaterial')
    bsdf = nt.nodes.new('ShaderNodeBsdfPrincipled')
    bsdf.inputs['IOR'].default_value = 1.48
    bsdf.inputs['Specular IOR Level'].default_value = 0.26
    bsdf.inputs['Coat Weight'].default_value = 0.08
    bsdf.inputs['Coat Roughness'].default_value = 0.38

    tc = nt.nodes.new('ShaderNodeTexCoord')
    mp = nt.nodes.new('ShaderNodeMapping')
    # Natural oak planks along X
    mp.inputs['Scale'].default_value = (2.8, 2.8, 2.8)
    nt.links.new(tc.outputs['UV'], mp.inputs['Vector'])

    tex_col = nt.nodes.new('ShaderNodeTexImage')
    tex_col.image = bpy.data.images.load(os.path.join(wood_dir, "Wood094_2K-JPG_Color.jpg"))
    tex_col.interpolation = 'Cubic'
    nt.links.new(mp.outputs['Vector'], tex_col.inputs['Vector'])

    # Rich, natural warm Scandinavian oak (not washed-out peach)
    hsv = nt.nodes.new('ShaderNodeHueSaturation')
    hsv.inputs['Saturation'].default_value = 0.78
    hsv.inputs['Value'].default_value = 0.78
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
    rgh_map.inputs['To Min'].default_value = 0.38
    rgh_map.inputs['To Max'].default_value = 0.62
    nt.links.new(tex_rgh.outputs['Color'], rgh_map.inputs['Value'])
    nt.links.new(rgh_map.outputs['Result'], bsdf.inputs['Roughness'])

    tex_nrm = nt.nodes.new('ShaderNodeTexImage')
    tex_nrm.image = bpy.data.images.load(os.path.join(wood_dir, "Wood094_2K-JPG_NormalGL.jpg"))
    tex_nrm.image.colorspace_settings.name = 'Non-Color'
    tex_nrm.interpolation = 'Cubic'
    nt.links.new(mp.outputs['Vector'], tex_nrm.inputs['Vector'])
    nrm = nt.nodes.new('ShaderNodeNormalMap')
    nrm.inputs['Strength'].default_value = 0.32
    nt.links.new(tex_nrm.outputs['Color'], nrm.inputs['Color'])
    nt.links.new(nrm.outputs['Normal'], bsdf.inputs['Normal'])

    nt.links.new(bsdf.outputs['BSDF'], m_out.inputs['Surface'])

    # Desk plane at Z = 0
    bpy.ops.mesh.primitive_plane_add(size=2.6 * u, location=(0, 0.25 * u, 0))
    desk = bpy.context.active_object
    desk.name = "StudioDesk"
    desk.data.materials.append(mat_desk)

    # Warm architectural gallery plaster wall behind desk (soft warm stone/linen, NEVER clipped white!)
    mat_wall = bpy.data.materials.new("StudioWall")
    mat_wall.use_nodes = True
    wnt = mat_wall.node_tree
    wnt.nodes.clear()
    w_out = wnt.nodes.new('ShaderNodeOutputMaterial')
    w_bsdf = wnt.nodes.new('ShaderNodeBsdfPrincipled')
    w_bsdf.inputs['Roughness'].default_value = 0.94
    w_bsdf.inputs['Specular IOR Level'].default_value = 0.04

    wtc = wnt.nodes.new('ShaderNodeTexCoord')
    wsep = wnt.nodes.new('ShaderNodeSeparateXYZ')
    wnt.links.new(wtc.outputs['UV'], wsep.inputs['Vector'])
    wramp = wnt.nodes.new('ShaderNodeValToRGB')
    wramp.color_ramp.elements[0].position = 0.0
    wramp.color_ramp.elements[0].color = (0.34, 0.31, 0.27, 1.0)
    wramp.color_ramp.elements[1].position = 1.0
    wramp.color_ramp.elements[1].color = (0.48, 0.45, 0.40, 1.0)
    wnt.links.new(wsep.outputs['Y'], wramp.inputs['Fac'])
    wnt.links.new(wramp.outputs['Color'], w_bsdf.inputs['Base Color'])
    wnt.links.new(w_bsdf.outputs['BSDF'], w_out.inputs['Surface'])

    bpy.ops.mesh.primitive_plane_add(size=4.0 * u, location=(0, 0.85 * u, 0.95 * u), rotation=(math.radians(90), 0, 0))
    wall = bpy.context.active_object
    wall.name = "StudioWall"
    wall.data.materials.append(mat_wall)

    # Studio lighting: sculptural warm sunlight key from upper-left + soft neutral fill + gentle rim
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

    # Warm afternoon window key (upper left, casting clean soft shadow across oak desk)
    add_area("KeyLight", (-0.85, -0.70, 0.90), (0.0, 0.05, 0.12), energy=20.0, size_x=0.75, size_y=0.65, color=(1.0, 0.95, 0.88))
    # Soft fill from right-front so metallic bevels and silver aluminum read crisply without blowing out
    add_area("FillLight", (0.95, -0.60, 0.55), (0.0, 0.0, 0.10), energy=7.5, size_x=0.95, size_y=0.65, color=(0.94, 0.96, 1.0))
    # Subtle top-back rim to kiss titanium/aluminum edges
    add_area("RimLight", (0.10, 0.50, 0.85), (0.0, 0.0, 0.10), energy=9.5, size_x=1.0, size_y=0.30, color=(1.0, 0.98, 0.94))


def make_screen_material(img_path, name="AppScreenMat", flip_u=False, flip_v=False, glass_sheen=0.035):
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
    gloss.inputs['Roughness'].default_value = 0.035

    lw = nt.nodes.new('ShaderNodeLayerWeight')
    lw.inputs['Blend'].default_value = 0.08
    mul = nt.nodes.new('ShaderNodeMath')
    mul.operation = 'MULTIPLY'
    mul.inputs[1].default_value = glass_sheen
    nt.links.new(lw.outputs['Fresnel'], mul.inputs[0])

    tc = nt.nodes.new('ShaderNodeTexCoord')
    mp = nt.nodes.new('ShaderNodeMapping')
    mp.inputs['Location'].default_value = (1.0 if flip_u else 0.0, 1.0 if flip_v else 0.0, 0.0)
    mp.inputs['Scale'].default_value = (-1.0 if flip_u else 1.0, -1.0 if flip_v else 1.0, 1.0)
    nt.links.new(tc.outputs['UV'], mp.inputs['Vector'])

    tex = nt.nodes.new('ShaderNodeTexImage')
    img = bpy.data.images.load(img_path)
    img.colorspace_settings.name = 'sRGB'
    tex.image = img
    tex.interpolation = 'Cubic'
    tex.extension = 'EXTEND'
    nt.links.new(mp.outputs['Vector'], tex.inputs['Vector'])

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
    cx = 0.5 * (x0 + x1)
    cy = 0.5 * (y0 + y1)
    root.location.x -= cx
    root.location.y -= cy
    root.location.z -= z0 - z_offset
    bpy.context.view_layer.update()
    return mesh_world_bb(objs)


def add_camera(loc, target, lens_mm=85.0, dof_fstop=None):
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
        # Hide AR Quick Look invisible collision/shadow bounding box
        hide_objs(objs, {"lJPfQMFXvvcmdtA"})
        scr = bpy.data.objects["UXtsBZYlaUvHoEh"]
        scr.data.materials.clear()
        scr.data.materials.append(make_screen_material(screen_img, "DuoScreen"))
        # Gentle natural reclined pose on desk (~10° tilt back, 12° yaw toward key light)
        root.rotation_euler = (math.radians(-10.0), 0.0, math.radians(-12.0))
        (x0, x1), (y0, y1), (z0, z1) = rest_on_desk(root, objs)
        cx, cy, cz = 0.5*(x0+x1), 0.5*(y0+y1), 0.5*(z0+z1)
        # Editorial 78mm framing with generous warm oak desk + gallery wall breathing room
        add_camera((cx - 2.2, cy - 46.0, cz + 5.6), (cx, cy, cz - 0.3), lens_mm=78.0, dof_fstop=8.0)

    elif device == "android":
        bpy.ops.import_scene.gltf(filepath=os.path.join(models_dir, "galaxy-s25-ultra.glb"))
        root, objs = group_imported(before, "GalaxyS25Ultra")
        scr = bpy.data.objects["Display_ActiveArea"]
        scr.data.materials.clear()
        scr.data.materials.append(make_screen_material(screen_img, "AndroidScreen"))
        # Slightly reclined (~11° tilt back, 13° yaw) standing cleanly on oak desk
        root.rotation_euler = (math.radians(-11.0), 0.0, math.radians(-13.0))
        (x0, x1), (y0, y1), (z0, z1) = rest_on_desk(root, objs)
        cx, cy, cz = 0.5*(x0+x1), 0.5*(y0+y1), 0.5*(z0+z1)
        # Full Galaxy S25 Ultra inside frame with clean top/bottom breathing room (~82% of height)
        add_camera((cx - 0.040, cy - 0.55, cz + 0.056), (cx, cy, cz - 0.002), lens_mm=76.0, dof_fstop=8.0)

    elif device == "desk":
        bpy.ops.wm.usd_import(filepath=os.path.join(models_dir, "macbook-pro-14-silver.usdz"))
        root, objs = group_imported(before, "MacBookPro14")
        hide_objs(objs, {"wCXoRkwGQmDbgYl"})
        scr = bpy.data.objects["TqWsnNZeaiebqoe"]
        scr.data.materials.clear()
        scr.data.materials.append(make_screen_material(screen_img, "MacBookScreen"))
        # Natural desk yaw (~13° showing full precision unibody, keyboard, trackpad + XDR screen)
        root.rotation_euler = (0.0, 0.0, math.radians(-13.0))
        (x0, x1), (y0, y1), (z0, z1) = rest_on_desk(root, objs)
        cx, cy, cz = 0.5*(x0+x1), 0.5*(y0+y1), 0.5*(z0+z1)
        add_camera((cx - 8.5, cy - 82.0, cz + 15.0), (cx + 0.4, cy + 1.5, cz - 0.8), lens_mm=68.0, dof_fstop=8.0)

    elif device == "web":
        bpy.ops.wm.usd_import(filepath=os.path.join(models_dir, "studio-display.usdz"))
        root, objs = group_imported(before, "StudioDisplay")
        # Hide any 16-face full-BB AR proxy box if present
        for o in objs:
            if o.type == 'MESH' and len(o.data.polygons) <= 24:
                bb = [o.matrix_world @ mathutils.Vector(c) for c in o.bound_box]
                if max(p.x for p in bb) - min(p.x for p in bb) > 61.5:
                    o.hide_render = True
                    o.hide_viewport = True
        scr = bpy.data.objects["IZJsAfohLAwOHok"]
        scr.data.materials.clear()
        scr.data.materials.append(make_screen_material(screen_img, "StudioDisplayScreen"))
        root.rotation_euler = (0.0, 0.0, math.radians(-11.0))
        (x0, x1), (y0, y1), (z0, z1) = rest_on_desk(root, objs)
        cx, cy, cz = 0.5*(x0+x1), 0.5*(y0+y1), 0.5*(z0+z1)
        add_camera((cx - 11.5, cy - 154.0, cz + 8.5), (cx, cy, cz - 1.2), lens_mm=68.0, dof_fstop=8.0)

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
