"""LAB connected components within a configurable bench observation window."""
import config as C
from color_core import COLORS, choose_color
from arrow_core import extract_mask, classify
from arrow_templates import TEMPLATES

DEFAULT_LAB = ((20,100,21,127,5,127), (15,95,-128,-16,-5,100),
               (5,80,-10,100,-128,-16), (35,100,-15,20,30,127))


def roi_rect(width,height,tracking=False,field=False):
    coords = C.FIELD_COLOR_ROI if field else (C.TRACK_ROI if tracking else C.COLOR_ROI)
    rx,ry,rw,rh = coords
    if rx<0 or ry<0 or rw<=0 or rh<=0 or rx+rw>1 or ry+rh>1:
        raise ValueError("COLOR_ROI must fit normalized image coordinates")
    return int(rx*width),int(ry*height),int(rw*width),int(rh*height)


def looks_like_arrow(img,box):
    # Suppress blue signs matching the known white-arrow geometry, not all blue objects.
    mask,count = extract_mask(img.get_pixel,box,32,C.WHITE_MIN,C.WHITE_SPREAD)
    if count < 25:
        return False
    return classify(mask,TEMPLATES,.40,.05)["label"] != "unknown"


def detect_colors(img,tracking=False,field=False,sign_box=None):
    roi = roi_rect(img.width(),img.height(),tracking,field)
    minimum = getattr(C,"COLOR_MIN_PIXELS",500)
    blobs = img.find_blobs(list(getattr(C,"COLOR_LAB",DEFAULT_LAB)),roi=roi,
                          pixels_threshold=minimum,area_threshold=minimum,
                          merge=False)
    candidates = []
    rejected=[]
    present = False
    x0,y0,rw,rh = roi
    for b in blobs:
        def reject(reason):
            if len(rejected)<32:
                rejected.append({'box':b.rect(),'code':b.code(),'pixels':b.pixels(),'reason':reason})
        if b.pixels() < minimum or b.w()<16 or b.h()<16:
            reject('small')
            continue
        # Reject ROI-clipped objects until they are fully inside it.
        clipped=b.x()<=x0+1 or b.y()<=y0+1 or b.x()+b.w()>=x0+rw-1 or b.y()+b.h()>=y0+rh-1
        if clipped and not tracking:
            reject('clipped')
            continue
        if not .35<=b.w()/b.h()<=2.8 or b.pixels()/(b.w()*b.h())<.35:
            reject('shape_or_density')
            continue
        code = b.code()
        if code not in (1,2,4,8):
            reject('mixed_threshold')
            continue
        label = COLORS[(1,2,4,8).index(code)]
        if field and label == "blue" and sign_box:
            sx,sy,sw,sh = sign_box
            cx,cy = b.x()+b.w()/2,b.y()+b.h()/2
            if sx <= cx < sx+sw and sy <= cy < sy+sh:
                reject('arrow_sign')
                continue
        if label=="blue" and not clipped and looks_like_arrow(img,b.rect()):
            reject('arrow_sign')
            continue
        # Only eligible targets block rearming. Clipped background patches,
        # tiny/noisy shapes and vetoed arrow signs aren't an ongoing color cube.
        present = True
        candidates.append({"label":label,"box":b.rect(),"pixels":b.pixels(),'clipped':clipped})
    candidates.sort(key=lambda c:c['pixels'],reverse=True)
    discarded=max(0,len(candidates)-24)
    candidates=candidates[:24]
    best = choose_color(candidates,getattr(C,"COLOR_DOMINANCE",1.6))
    if best is None:
        return {"label":"unknown","box":None,"pixels":0,"present":present,"roi":roi,
                'candidates':candidates,'rejected':rejected,'candidate_overflow':discarded}
    result = dict(best)
    result.update({"present":True,"roi":roi})
    result.update({'candidates':candidates,'rejected':rejected,'candidate_overflow':discarded})
    return result


def detect_multi_colors(img,field=False,sign_box=None):
    return detect_colors(img,tracking=True,field=field,sign_box=sign_box)
