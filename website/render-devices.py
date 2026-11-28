"""Dark-studio renders of the #devices shots: a real device model with an apps/mbui screen on it.

  blender -b -P website/render-devices.py -- --models DIR --device iphone|android|mac|linux|windows \
      --screen screen.png --out out.png [--size 3840x2880] [--samples 256]

Models (website/devices.sh downloads them into --models): Apple's iPhone 18 Pro and MacBook Air 15" AR models
(USDZ), Samsung's Galaxy S25+ (GLB), "Modern Slim Laptop" by Mraz3D (CC BY 4.0, credited in the site footer) for
the Windows laptop, and Poly Haven's CC0 studio_small_09 HDRI for reflections.

Look: a black backdrop with a soft vignette, one large soft key and two thin rim strips that draw the metal edges,
the HDRI only in reflections; phones float, laptops stand on a near-black floor that fades out (no horizon) and the
rims are light-linked to the device so they never streak the floor. The screen is an emission of the exact pixels:
the film is Standard and only the hardware gets a highlight roll-off and denoising in the compositor
(final = rolloff(denoise(combined - emit)) + emit), so UI text is never smeared or tone-mapped.
"""
import bpy, math, mathutils, os, sys

A = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
def arg(name, default=None):
    return A[A.index(name) + 1] if name in A else default

DEVICE = arg("--device", "iphone")
SCREEN = arg("--screen")
OUT = arg("--out", "/tmp/out.png")
W, H = (int(x) for x in arg("--size", "960x720").split("x"))
SAMPLES = int(arg("--samples", "32"))
MODELS = arg("--models", ".")

V = mathutils.Vector


def setup_scene():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    sc = bpy.context.scene
    sc.render.engine = "CYCLES"
    prefs = bpy.context.preferences.addons["cycles"].preferences
    sc.cycles.device = "CPU"
    for backend in ("OPTIX", "CUDA"):
        try:
            prefs.compute_device_type = backend
            prefs.get_devices()
            gpus = [d for d in prefs.devices if d.type == backend]
            if gpus:
                for d in prefs.devices:
                    d.use = d.type == backend
                sc.cycles.device = "GPU"
                break
        except Exception:
            pass
    print("[render] device", sc.cycles.device)
    sc.cycles.samples = SAMPLES
    # every pixel takes every sample: adaptive sampling stops early on the flat screen and leaves its
    # glyph and bezel edges under-sampled (stair steps)
    sc.cycles.use_adaptive_sampling = False
    sc.cycles.use_denoising = False
    sc.cycles.max_bounces = 12
    sc.cycles.glossy_bounces = 8
    sc.cycles.transmission_bounces = 8
    sc.cycles.transparent_max_bounces = 16
    sc.cycles.sample_clamp_indirect = 3.0
    sc.cycles.pixel_filter_type = "BLACKMAN_HARRIS"
    sc.cycles.filter_width = 1.5
    sc.render.resolution_x, sc.render.resolution_y = W, H
    sc.render.resolution_percentage = 100
    sc.render.film_transparent = False
    sc.render.image_settings.file_format = "PNG"
    sc.render.image_settings.color_mode = "RGB"
    sc.render.image_settings.color_depth = "16"
    # The screen must keep its exact sRGB colours, so the film is Standard and the
    # hardware (everything but the screen's emission) gets its own highlight roll-off
    # in the compositor: final = rolloff(denoise(combined - emit)) + emit.
    sc.view_settings.view_transform = "Standard"
    sc.view_settings.look = "None"
    vl = sc.view_layers[0]
    vl.use_pass_emit = True
    vl.cycles.denoising_store_passes = True
    sc.use_nodes = True
    nt = sc.node_tree
    nt.nodes.clear()
    rl = nt.nodes.new("CompositorNodeRLayers")
    sub = nt.nodes.new("CompositorNodeMixRGB"); sub.blend_type = "SUBTRACT"
    nt.links.new(rl.outputs["Image"], sub.inputs[1]); nt.links.new(rl.outputs["Emit"], sub.inputs[2])
    den = nt.nodes.new("CompositorNodeDenoise"); den.prefilter = "ACCURATE"; den.use_hdr = True
    nt.links.new(sub.outputs["Image"], den.inputs["Image"])
    nt.links.new(rl.outputs["Denoising Normal"], den.inputs["Normal"])
    nt.links.new(rl.outputs["Denoising Albedo"], den.inputs["Albedo"])
    # Soft shoulder: identity below 0.6, smooth compression to 1.0 above (per channel).
    sep = nt.nodes.new("CompositorNodeSeparateColor")
    comb = nt.nodes.new("CompositorNodeCombineColor")
    nt.links.new(den.outputs["Image"], sep.inputs["Image"])
    for ch in ("Red", "Green", "Blue"):
        # y = x for x<t ; y = t + (1-t) * (1 - exp(-(x-t)/(1-t))) for x>=t
        t = 0.6
        s1 = nt.nodes.new("CompositorNodeMath"); s1.operation = "SUBTRACT"; s1.inputs[1].default_value = t
        nt.links.new(sep.outputs[ch], s1.inputs[0])
        mx = nt.nodes.new("CompositorNodeMath"); mx.operation = "MAXIMUM"; mx.inputs[1].default_value = 0.0
        nt.links.new(s1.outputs[0], mx.inputs[0])
        dv = nt.nodes.new("CompositorNodeMath"); dv.operation = "MULTIPLY"; dv.inputs[1].default_value = -1.0 / (1 - t)
        nt.links.new(mx.outputs[0], dv.inputs[0])
        ex = nt.nodes.new("CompositorNodeMath"); ex.operation = "EXPONENT"
        nt.links.new(dv.outputs[0], ex.inputs[0])
        om = nt.nodes.new("CompositorNodeMath"); om.operation = "SUBTRACT"; om.inputs[0].default_value = 1.0
        nt.links.new(ex.outputs[0], om.inputs[1])
        sc2 = nt.nodes.new("CompositorNodeMath"); sc2.operation = "MULTIPLY"; sc2.inputs[1].default_value = 1 - t
        nt.links.new(om.outputs[0], sc2.inputs[0])
        hi = nt.nodes.new("CompositorNodeMath"); hi.operation = "ADD"; hi.inputs[1].default_value = t
        nt.links.new(sc2.outputs[0], hi.inputs[0])
        lo = nt.nodes.new("CompositorNodeMath"); lo.operation = "MINIMUM"; lo.inputs[1].default_value = t
        nt.links.new(sep.outputs[ch], lo.inputs[0])
        # x<t -> lo == x and mx == 0 -> hi == t; result = lo + hi - t
        a = nt.nodes.new("CompositorNodeMath"); a.operation = "ADD"
        nt.links.new(lo.outputs[0], a.inputs[0]); nt.links.new(hi.outputs[0], a.inputs[1])
        b = nt.nodes.new("CompositorNodeMath"); b.operation = "SUBTRACT"; b.inputs[1].default_value = t
        nt.links.new(a.outputs[0], b.inputs[0])
        nt.links.new(b.outputs[0], comb.inputs[ch])
    add = nt.nodes.new("CompositorNodeMixRGB"); add.blend_type = "ADD"
    nt.links.new(comb.outputs["Image"], add.inputs[1]); nt.links.new(rl.outputs["Emit"], add.inputs[2])
    out = nt.nodes.new("CompositorNodeComposite")
    nt.links.new(add.outputs["Image"], out.inputs["Image"])
    return sc


def world(u, hdri_strength=0.35, hdri_rot=0.0, bg=(0.030, 0.030, 0.033), bg_edge=(0.006, 0.006, 0.007)):
    """Reflections come from a studio HDRI (dimmed); the camera sees a soft dark vignette."""
    w = bpy.data.worlds.new("W"); bpy.context.scene.world = w
    w.use_nodes = True
    n, l = w.node_tree.nodes, w.node_tree.links
    n.clear()
    out = n.new("ShaderNodeOutputWorld")
    mix = n.new("ShaderNodeMixShader")
    lp = n.new("ShaderNodeLightPath")
    env_bg = n.new("ShaderNodeBackground"); env_bg.inputs["Strength"].default_value = hdri_strength
    tc = n.new("ShaderNodeTexCoord"); mp = n.new("ShaderNodeMapping")
    mp.inputs["Rotation"].default_value = (0, 0, math.radians(hdri_rot))
    env = n.new("ShaderNodeTexEnvironment")
    env.image = bpy.data.images.load(os.path.join(MODELS, "studio_small_09_4k.exr"))
    l.new(tc.outputs["Generated"], mp.inputs["Vector"]); l.new(mp.outputs["Vector"], env.inputs["Vector"])
    l.new(env.outputs["Color"], env_bg.inputs["Color"])
    # Camera background: radial vignette from window coordinates.
    cam_bg = n.new("ShaderNodeBackground")
    win = n.new("ShaderNodeTexCoord")
    m2 = n.new("ShaderNodeMapping"); m2.inputs["Location"].default_value = (-0.5, -0.56, 0)
    m2.inputs["Scale"].default_value = (1.0, H / W, 1)
    l.new(win.outputs["Window"], m2.inputs["Vector"])
    ln = n.new("ShaderNodeVectorMath"); ln.operation = "LENGTH"
    l.new(m2.outputs["Vector"], ln.inputs[0])
    ramp = n.new("ShaderNodeValToRGB")
    ramp.color_ramp.interpolation = "EASE"
    ramp.color_ramp.elements[0].position = 0.0; ramp.color_ramp.elements[0].color = (*bg, 1)
    ramp.color_ramp.elements[1].position = 0.75; ramp.color_ramp.elements[1].color = (*bg_edge, 1)
    l.new(ln.outputs["Value"], ramp.inputs["Fac"])
    l.new(ramp.outputs["Color"], cam_bg.inputs["Color"])
    l.new(lp.outputs["Is Camera Ray"], mix.inputs["Fac"])
    l.new(env_bg.outputs["Background"], mix.inputs[1]); l.new(cam_bg.outputs["Background"], mix.inputs[2])
    l.new(mix.outputs["Shader"], out.inputs["Surface"])


def area(name, loc, target, power, sx, sy, color=(1, 1, 1), u=1.0, spread=180, camera=False):
    d = bpy.data.lights.new(name, "AREA"); d.shape = "RECTANGLE"
    d.size, d.size_y = sx * u, sy * u
    d.energy = power * u * u
    d.color = color
    d.spread = math.radians(spread)
    o = bpy.data.objects.new(name, d); bpy.context.collection.objects.link(o)
    o.location = V(loc) * u
    o.rotation_euler = (V(target) * u - o.location).to_track_quat("-Z", "Y").to_euler()
    o.visible_camera = camera
    return o


def camera(loc, target, lens=85.0, fstop=None):
    """Scenes are modelled in centimetres but Blender reads them as metres, so the f-stop only
    softens the far floor and backdrop a little; the device and its screen stay sharp."""
    cd = bpy.data.cameras.new("Cam"); cd.lens = lens; cd.sensor_width = 36
    cd.clip_start = 0.1; cd.clip_end = 1e5
    c = bpy.data.objects.new("Cam", cd); bpy.context.collection.objects.link(c)
    c.location = V(loc)
    c.rotation_euler = (V(target) - c.location).to_track_quat("-Z", "Y").to_euler()
    if fstop:
        cd.dof.use_dof = True; cd.dof.focus_distance = (V(target) - c.location).length; cd.dof.aperture_fstop = fstop
    bpy.context.scene.camera = c
    return c


GLOW = float(arg("--glow", "2.5"))


def screen_material(path, name="Screen", sheen=0.006):
    """The app's pixels as emission, plus the faintest reflection of a matte (anti-glare) screen."""
    m = bpy.data.materials.new(name); m.use_nodes = True
    n, l = m.node_tree.nodes, m.node_tree.links
    n.clear()
    out = n.new("ShaderNodeOutputMaterial")
    tex = n.new("ShaderNodeTexImage"); tex.image = bpy.data.images.load(path)
    tex.interpolation = "Linear"; tex.extension = "EXTEND"
    em = n.new("ShaderNodeEmission")
    l.new(tex.outputs["Color"], em.inputs["Color"])
    # the camera sees the exact pixels (strength 1); every other ray sees a brighter screen, so it is
    # the light that falls on the keyboard, the bezel and the floor
    lp = n.new("ShaderNodeLightPath")
    st = n.new("ShaderNodeMapRange")
    st.inputs["From Min"].default_value = 0.0; st.inputs["From Max"].default_value = 1.0
    st.inputs["To Min"].default_value = GLOW; st.inputs["To Max"].default_value = 1.0
    l.new(lp.outputs["Is Camera Ray"], st.inputs["Value"])
    l.new(st.outputs["Result"], em.inputs["Strength"])
    gl = n.new("ShaderNodeBsdfGlossy"); gl.inputs["Roughness"].default_value = 0.02
    none = n.new("ShaderNodeEmission"); none.inputs["Strength"].default_value = 0.0
    glass = n.new("ShaderNodeMixShader"); glass.inputs["Fac"].default_value = sheen
    l.new(none.outputs[0], glass.inputs[1]); l.new(gl.outputs[0], glass.inputs[2])
    add = n.new("ShaderNodeAddShader")
    l.new(em.outputs[0], add.inputs[0]); l.new(glass.outputs[0], add.inputs[1])
    l.new(add.outputs[0], out.inputs["Surface"])
    return m


def principled(mat):
    if not mat or not mat.use_nodes:
        return None
    return next((x for x in mat.node_tree.nodes if x.type == "BSDF_PRINCIPLED"), None)


def import_model(path):
    before = set(bpy.data.objects)
    if path.endswith(".glb"):
        bpy.ops.import_scene.gltf(filepath=path)
    else:
        bpy.ops.wm.usd_import(filepath=path)
    objs = [o for o in bpy.data.objects if o not in before]
    root = bpy.data.objects.new("Root", None); bpy.context.collection.objects.link(root)
    for o in objs:
        if o.parent is None:
            o.parent = root
    return root, objs


def bbox(objs):
    bpy.context.view_layer.update()
    pts = [o.matrix_world @ V(c) for o in objs if o.type == "MESH" and not o.hide_render for c in o.bound_box]
    lo = V((min(p.x for p in pts), min(p.y for p in pts), min(p.z for p in pts)))
    hi = V((max(p.x for p in pts), max(p.y for p in pts), max(p.z for p in pts)))
    return lo, hi


def keep_branch(objs, keep_name, drop_name):
    def chain(o):
        c = []
        while o is not None:
            c.append(o); o = o.parent
        return c[::-1]
    a, b = chain(bpy.data.objects[keep_name]), chain(bpy.data.objects[drop_name])
    br = next(x for x, y in zip(a, b) if x != y)
    kept = []
    for o in objs:
        if br in chain(o):
            kept.append(o)
        else:
            o.hide_render = True; o.hide_viewport = True
    return kept


def recolor(objs, pred, color, metallic=None, rough=None):
    seen = set()
    for o in objs:
        if o.type != "MESH":
            continue
        for m in o.data.materials:
            b = principled(m)
            if not b or m.name in seen:
                continue
            seen.add(m.name)
            bc = b.inputs["Base Color"]
            if bc.is_linked:
                continue
            if pred(tuple(bc.default_value[:3]), b):
                bc.default_value = (*color, 1)
                if metallic is not None and not b.inputs["Metallic"].is_linked:
                    b.inputs["Metallic"].default_value = metallic
                if rough is not None:
                    for lk in list(b.inputs["Roughness"].links):
                        m.node_tree.links.remove(lk)
                    b.inputs["Roughness"].default_value = rough


def tint_textured(objs, sat=0.0, val=0.6, skip=()):
    seen = set()
    for o in objs:
        if o.type != "MESH" or o.name in skip:
            continue
        for m in o.data.materials:
            b = principled(m)
            if not b or m.name in seen:
                continue
            seen.add(m.name)
            bc = b.inputs["Base Color"]
            if not bc.is_linked:
                continue
            src = bc.links[0].from_socket
            hs = m.node_tree.nodes.new("ShaderNodeHueSaturation")
            hs.inputs["Saturation"].default_value = sat
            hs.inputs["Value"].default_value = val
            m.node_tree.links.new(src, hs.inputs["Color"])
            m.node_tree.links.new(hs.outputs["Color"], bc)


def glassify_black(objs, rough=0.06):
    """AR models ship pure-black rough materials for cover glass; make them glossy black glass."""
    seen = set()
    for o in objs:
        if o.type != "MESH":
            continue
        for m in o.data.materials:
            b = principled(m)
            if not b or m.name in seen:
                continue
            seen.add(m.name)
            bc = b.inputs["Base Color"]
            if bc.is_linked or b.inputs["Roughness"].is_linked:
                continue
            c = bc.default_value
            if max(c[:3]) < 0.012 and b.inputs["Roughness"].default_value > 0.9 and b.inputs["Metallic"].default_value < 0.1:
                bc.default_value = (0.004, 0.004, 0.005, 1)
                b.inputs["Roughness"].default_value = rough
                b.inputs["Coat Weight"].default_value = 1.0
                b.inputs["Coat Roughness"].default_value = 0.02


def render():
    sc = bpy.context.scene
    sc.render.filepath = OUT
    bpy.ops.render.render(write_still=True)
    print("RENDERED", OUT)


FRAME = (0.055, 0.056, 0.060)
TRIM = (0.02, 0.02, 0.022)


def iphone():
    setup_scene()
    u = 1.0  # model in cm
    root, objs = import_model(os.path.join(MODELS, "iphone-18-pro.usdz"))
    objs = keep_branch(objs, "EHjrGDHNHzgNjtE", "EHjrGDHNHzgNjtE.001")
    reddish = lambda c, b: c[0] > c[1] * 1.4 and c[0] > 0.03
    recolor(objs, lambda c, b: reddish(c, b) and b.inputs["Metallic"].default_value >= 0.6,
            FRAME, metallic=1.0, rough=float(arg("--fr", "0.22")))
    recolor(objs, lambda c, b: reddish(c, b), TRIM)
    glassify_black(objs)
    tint_textured(objs, skip=("EHjrGDHNHzgNjtE",))
    scr = bpy.data.objects["EHjrGDHNHzgNjtE"]
    scr.data.materials.clear(); scr.data.materials.append(screen_material(SCREEN))
    root.rotation_euler = (math.radians(-float(arg("--tilt", "5"))), 0, math.radians(-float(arg("--yaw", "6"))))
    lo, hi = bbox(objs)
    root.location -= (lo + hi) / 2
    lo, hi = bbox(objs)
    c = (lo + hi) / 2
    world(u, hdri_strength=float(arg("--hdri", "0.12")), hdri_rot=float(arg("--hrot", "120")), bg=(0.010, 0.010, 0.011), bg_edge=(0.0, 0.0, 0.0))
    k = float(arg("--k", "1"))
    # key: big soft box high front-left; rims: tall thin strips behind each side; top strip
    area("Key", (-40, -50, 45), (0, 0, 0), 9e3 * k, 50, 35, (1, 0.985, 0.97))
    area("RimL", (-30, 35, 0), (0, 0, 0), 1.6e4 * k, 3, 70, (1, 0.98, 0.96))
    area("RimR", (32, 30, 8), (0, 0, 0), 1.8e4 * k, 3, 70, (0.95, 0.97, 1))
    area("Top", (5, 15, 45), (0, 0, 0), 5e3 * k, 40, 4)
    camera((c.x + 2, c.y - float(arg("--dist", "58")), c.z + 3), (c.x, c.y, c.z + float(arg("--tz", "0.8"))), lens=70, fstop=float(arg("--f", "2.8")))
    render()


def android():
    setup_scene()
    root, objs = import_model(os.path.join(MODELS, "galaxy-s25-plus.glb"))
    root.scale = (100, 100, 100)
    scr = bpy.data.objects["Display_ActiveArea"]
    scr.data.materials.clear(); scr.data.materials.append(screen_material(SCREEN))
    glassify_black([o for o in objs if o.name != "Black_Hole"])
    for o in objs:
        for m in (o.data.materials if o.type == "MESH" else []):
            b = principled(m)
            if b and m.name in ("Rearcase", "Antenna_Plastic", "BackCam_Frame_2"):
                b.inputs["Base Color"].default_value = (0.018, 0.026, 0.055, 1)
                b.inputs["Roughness"].default_value = 0.22
    root.rotation_euler = (math.radians(-float(arg("--tilt", "5"))), 0, math.radians(float(arg("--yaw", "6"))))
    lo, hi = bbox(objs)
    root.location -= (lo + hi) / 2
    lo, hi = bbox(objs)
    c = (lo + hi) / 2
    world(1, hdri_strength=float(arg("--hdri", "0.12")), hdri_rot=float(arg("--hrot", "120")), bg=(0.010, 0.010, 0.011), bg_edge=(0.0, 0.0, 0.0))
    k = float(arg("--k", "1.4"))
    area("Key", (40, -50, 45), (0, 0, 0), 9e3 * k, 50, 35, (1, 0.985, 0.97))
    area("RimL", (-32, 30, 8), (0, 0, 0), 1.8e4 * k, 3, 70, (1, 0.98, 0.96))
    area("RimR", (30, 35, 0), (0, 0, 0), 1.6e4 * k, 3, 70, (0.95, 0.97, 1))
    area("Top", (-5, 15, 45), (0, 0, 0), 5e3 * k, 40, 4)
    camera((c.x - 2, c.y - float(arg("--dist", "54")), c.z + 3), (c.x, c.y, c.z + float(arg("--tz", "0.8"))), lens=70, fstop=float(arg("--f", "2.8")))
    render()


def floor(color=(0.0, 0.0, 0.0), rough=0.2):
    m = bpy.data.materials.new("Floor"); m.use_nodes = True
    b = principled(m)
    b.inputs["Base Color"].default_value = (*color, 1)
    b.inputs["Roughness"].default_value = rough
    b.inputs["Specular IOR Level"].default_value = float(arg("--fspec", "0.25"))
    # fade the floor out radially so it melts into the black backdrop (no horizon)
    n, l = m.node_tree.nodes, m.node_tree.links
    out = next(x for x in n if x.type == "OUTPUT_MATERIAL")
    tc = n.new("ShaderNodeTexCoord")
    ln = n.new("ShaderNodeVectorMath"); ln.operation = "LENGTH"
    l.new(tc.outputs["Object"], ln.inputs[0])
    rp = n.new("ShaderNodeMapRange"); rp.inputs["From Min"].default_value = float(arg("--fade0", "35")); rp.inputs["From Max"].default_value = float(arg("--fade1", "75"))
    l.new(ln.outputs["Value"], rp.inputs["Value"])
    rp.interpolation_type = "SMOOTHSTEP"
    tr = n.new("ShaderNodeBsdfTransparent")
    mx = n.new("ShaderNodeMixShader")
    l.new(rp.outputs["Result"], mx.inputs["Fac"])
    l.new(b.outputs["BSDF"], mx.inputs[1]); l.new(tr.outputs["BSDF"], mx.inputs[2])
    l.new(mx.outputs["Shader"], out.inputs["Surface"])
    bpy.ops.mesh.primitive_plane_add(size=2000, location=(0, 0, 0))
    f = bpy.context.active_object
    f.data.materials.append(m)
    return f


def set_mat(o, color, rough, metallic=0.0, coat=0.0):
    m = bpy.data.materials.new(o.name + "_m"); m.use_nodes = True
    b = principled(m)
    b.inputs["Base Color"].default_value = (*color, 1)
    b.inputs["Roughness"].default_value = rough
    b.inputs["Metallic"].default_value = metallic
    b.inputs["Coat Weight"].default_value = coat
    b.inputs["Coat Roughness"].default_value = 0.03
    o.data.materials.clear(); o.data.materials.append(m)


def place_on_floor(root, objs, yaw):
    root.rotation_euler = (0, 0, math.radians(yaw))
    lo, hi = bbox(objs)
    root.location.x -= (lo.x + hi.x) / 2
    root.location.y -= (lo.y + hi.y) / 2
    root.location.z -= lo.z
    return bbox(objs)


def lights_laptop(k, floor_obj, mirror=1):
    """The screen is the key light. A dim soft fill from the front keeps the deck readable and one
    thin strip high behind draws the lid and deck edges; neither lights the floor."""
    lights = [area("Fill", (-50 * mirror, -80, 60), (0, 5, 5), 6e3 * k, 90, 60, (1, 0.985, 0.97)),
              area("Rim", (30 * mirror, 70, 60), (0, 5, 5), 2.2e4 * k, 90, 4, (1, 0.98, 0.96))]
    coll = bpy.data.collections.new("Device")
    for o in bpy.data.objects:
        if o.type == "MESH" and o is not floor_obj:
            coll.objects.link(o)
    for r in lights:
        r.light_linking.receiver_collection = coll


def mac():
    setup_scene()
    root, objs = import_model(os.path.join(MODELS, "macbook-air-15-silver.usdz"))
    for o in objs:
        if o.type != "MESH":
            continue
        if o.name == "OQzaQDtbMVhhlAr":
            o.data.materials.clear(); o.data.materials.append(screen_material(SCREEN))
        elif o.name == "awCetlAgwzdhTcS":  # lid inner black border = cover glass
            set_mat(o, (0.003, 0.003, 0.004), 0.05, coat=1.0)
        elif o.name == "czojSFNuFKxNgsc":  # key legends
            set_mat(o, (0.55, 0.55, 0.56), 0.5)
    lo, hi = place_on_floor(root, objs, -float(arg("--yaw", "6")))
    c = (lo + hi) / 2
    fl = floor()
    world(1, hdri_strength=float(arg("--hdri", "0")), hdri_rot=float(arg("--hrot", "120")), bg=(0.010, 0.010, 0.011), bg_edge=(0.0, 0.0, 0.0))
    lights_laptop(float(arg("--k", "1")), fl)
    d = float(arg("--dist", "120"))
    camera((c.x - d * 0.18, c.y - d, c.z + d * float(arg("--el", "0.16"))), (c.x, c.y + float(arg("--ty", "1")), c.z + float(arg("--tz", "1.5"))), lens=float(arg("--lens", "60")), fstop=float(arg("--f", "5.6")))
    render()


WIN_BODY = (0.050, 0.053, 0.058)


def windows():
    setup_scene()
    root, objs = import_model(os.path.join(MODELS, "slim-laptop.glb"))
    root.scale = (100, 100, 100)
    bpy.context.view_layer.update()
    scr = bpy.data.objects["Screen_Screen_0"]
    me = scr.data
    # The model's UVs only cover part of the texture and run upside down: map the
    # quad's own corners to the full image (bottom edge = v 0).
    zs = [v.co.z for v in me.vertices]; xs = [v.co.x for v in me.vertices]
    z0, z1, x0, x1 = min(zs), max(zs), min(xs), max(xs)
    uv = me.uv_layers.active.data
    for poly in me.polygons:
        for li in poly.loop_indices:
            co = me.vertices[me.loops[li].vertex_index].co
            uv[li].uv = ((co.x - x0) / (x1 - x0), (co.z - z0) / (z1 - z0))
    scr.data.materials.clear(); scr.data.materials.append(screen_material(SCREEN))
    # the Windows laptop is graphite; the Linux one keeps the model's own light finish, so the two never look alike
    body = arg("--body", "light" if DEVICE == "linux" else "dark")
    for o in objs:
        if o.type != "MESH":
            continue
        for m in o.data.materials:
            b = principled(m)
            if not b:
                continue
            if m.name in ("Base", "Screen_Shiny_Border") and body == "dark":
                b.inputs["Base Color"].default_value = (*WIN_BODY, 1)
                b.inputs["Metallic"].default_value = 1.0
                b.inputs["Roughness"].default_value = 0.32
            elif m.name == "Screen_Frame":
                b.inputs["Base Color"].default_value = (0.003, 0.003, 0.004, 1)
                b.inputs["Roughness"].default_value = 0.05
                b.inputs["Coat Weight"].default_value = 1.0
            elif m.name == "Lights":
                b.inputs["Base Color"].default_value = (0.02, 0.02, 0.022, 1)
    lo, hi = place_on_floor(root, objs, float(arg("--yaw", "6")))
    c = (lo + hi) / 2
    fl = floor()
    world(1, hdri_strength=float(arg("--hdri", "0")), hdri_rot=float(arg("--hrot", "60")), bg=(0.010, 0.010, 0.011), bg_edge=(0.0, 0.0, 0.0))
    lights_laptop(float(arg("--k", "1")), fl, mirror=-1)
    d = float(arg("--dist", "100"))
    camera((c.x + d * 0.18, c.y - d, c.z + d * float(arg("--el", "0.16"))), (c.x, c.y + float(arg("--ty", "1")), c.z + float(arg("--tz", "1.5"))), lens=float(arg("--lens", "60")), fstop=float(arg("--f", "5.6")))
    render()


{"iphone": iphone, "android": android, "mac": mac, "windows": windows, "linux": windows}[DEVICE]()
