"""Converts Apple's SHARP checkpoint (single image -> 3D Gaussians) to a Core ML package
the app runs on the iPhone for Spatial Scene.

The package takes a 1536x1536 RGB image (pixel buffer, 0-255) and a disparity factor
(focal length / image width) and returns 1,179,648 Gaussians in SHARP's NDC space:
x, y in -1...1 across the (squeezed) image, z = metric depth. The app unprojects them
with the photo's real width, height and focal length.

Usage (Scripts/build-sharp-model.sh sets up the environment):
    python Tools/sharp/convert.py --checkpoint sharp.pt --output App/Models/SharpGaussians.mlpackage
"""

from __future__ import annotations

import argparse
import logging
from pathlib import Path

import coremltools as ct
import coremltools.optimize as cto
import numpy as np
import torch
import torch.nn as nn

from sharp.models import PredictorParams, create_predictor

SIZE = 1536
OUTPUTS = ["means", "scales", "quaternions", "colors", "opacities"]


class Traceable(nn.Module):
    """SHARP's forward pass without Python control flow, for torch.jit.trace."""

    def __init__(self, predictor: nn.Module) -> None:
        super().__init__()
        self.p = predictor

    def forward(self, image: torch.Tensor, disparity_factor: torch.Tensor):
        p = self.p
        mono = p.monodepth_model(image)
        disparity = mono.disparity.clamp(min=1e-4, max=1e4)
        depth = disparity_factor[:, None, None, None] / disparity
        depth, _ = p.depth_alignment(depth, None, mono.decoder_features)
        init = p.init_model(image, depth)
        features = p.feature_model(init.feature_input, encodings=mono.output_features)
        delta = p.prediction_head(features)
        g = p.gaussian_composer(delta=delta, base_values=init.gaussian_base_values, global_scale=init.global_scale)
        q = g.quaternions
        q = q / torch.sqrt(torch.clamp((q * q).sum(-1, keepdim=True), min=1e-12))
        return g.mean_vectors, g.singular_values, q, g.colors, g.opacities


def load(checkpoint: Path) -> nn.Module:
    predictor = create_predictor(PredictorParams())
    predictor.load_state_dict(torch.load(checkpoint, weights_only=True, map_location="cpu"))
    predictor.eval()
    predictor.depth_alignment.scale_map_estimator = None
    return predictor


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--weights", choices=["float16", "int8"], default="float16",
                        help="float16 (about 1.3 GB) or int8 linear-quantised weights (about 0.7 GB)")
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO)

    model = Traceable(load(args.checkpoint)).eval()
    torch.manual_seed(0)
    example = (torch.rand(1, 3, SIZE, SIZE), torch.tensor([1.0]))
    with torch.no_grad():
        traced = torch.jit.trace(model, example, strict=False, check_trace=False)

    mlmodel = ct.convert(
        traced,
        convert_to="mlprogram",
        inputs=[
            ct.ImageType(name="image", shape=(1, 3, SIZE, SIZE), scale=1 / 255.0, color_layout=ct.colorlayout.RGB),
            ct.TensorType(name="disparity_factor", shape=(1,), dtype=np.float32),
        ],
        outputs=[ct.TensorType(name=name, dtype=np.float32) for name in OUTPUTS],
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.iOS18,
    )
    if args.weights == "int8":
        config = cto.coreml.OptimizationConfig(
            global_config=cto.coreml.OpLinearQuantizerConfig(mode="linear_symmetric", weight_threshold=2048))
        mlmodel = cto.coreml.linear_quantize_weights(mlmodel, config)

    mlmodel.author = "Apple Inc. (SHARP, apple/ml-sharp)"
    mlmodel.license = "Apple Machine Learning Research Model License (research use only)"
    mlmodel.short_description = "SHARP: one photo to 3D Gaussians (NDC space; z is metric depth)."
    args.output.parent.mkdir(parents=True, exist_ok=True)
    mlmodel.save(str(args.output))
    logging.info("Saved %s", args.output)


if __name__ == "__main__":
    main()
