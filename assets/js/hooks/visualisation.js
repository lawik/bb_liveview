// SPDX-FileCopyrightText: 2025 James Harton
//
// SPDX-License-Identifier: Apache-2.0

/**
 * LiveView hook for Three.js robot visualisation.
 * Adapts the BB Kino visualisation for Phoenix LiveView.
 */

import * as THREE from "three";
import { OrbitControls } from "three/addons/controls/OrbitControls.js";
import { buildRobot, createScene } from "../visualisation/scene_builder.js";

/**
 * Auto-frame the camera to fit the robot in view.
 * Uses Z-up coordinate system.
 */
function frameRobot(camera, controls, robot) {
  // Compute bounding box
  const box = new THREE.Box3().setFromObject(robot);
  const center = box.getCenter(new THREE.Vector3());
  const size = box.getSize(new THREE.Vector3());

  // Get the maximum dimension
  const maxDim = Math.max(size.x, size.y, size.z);
  const fov = camera.fov * (Math.PI / 180);
  let cameraDistance = maxDim / (2 * Math.tan(fov / 2));

  // Add some padding
  cameraDistance *= 1.5;

  // Minimum distance
  cameraDistance = Math.max(cameraDistance, 0.5);

  // Position camera for Z-up view (looking from front-right, elevated)
  camera.position.set(
    center.x + cameraDistance * 0.7,
    center.y - cameraDistance * 0.7,
    center.z + cameraDistance * 0.5
  );

  // Ensure Z-up orientation
  camera.up.set(0, 0, 1);

  // Update controls target
  controls.target.copy(center);
  controls.update();
}

export const Visualisation = {
  mounted() {
    this.initVisualisation();
  },

  destroyed() {
    this.cleanup();
  },

  initVisualisation() {
    // Get initial data from data attributes
    const topologyData = this.el.dataset.topology;
    const positionsData = this.el.dataset.positions;
    const robotName = this.el.dataset.robotName || "Robot Visualisation";

    let topology = null;
    let positions = {};

    try {
      if (topologyData) {
        topology = JSON.parse(topologyData);
      }
      if (positionsData) {
        positions = JSON.parse(positionsData);
      }
    } catch (e) {
      console.error("Failed to parse visualisation data:", e);
      this.showError("Failed to load robot data");
      return;
    }

    // Create container structure
    this.el.innerHTML = `
      <div class="bb-vis">
        <div class="bb-vis-header">
          <span class="bb-vis-title">${robotName}</span>
          <div class="bb-vis-controls">
            <button class="bb-button bb-button-outline bb-vis-reset" title="Reset camera view">
              Reset View
            </button>
          </div>
        </div>
        <div class="bb-vis-container"></div>
      </div>
    `;

    const container = this.el.querySelector(".bb-vis-container");
    const resetViewBtn = this.el.querySelector(".bb-vis-reset");

    // Get dimensions
    const width = container.clientWidth || 600;
    const height = 400;

    // Create renderer
    this.renderer = new THREE.WebGLRenderer({ antialias: true });
    this.renderer.setSize(width, height);
    this.renderer.setPixelRatio(window.devicePixelRatio);
    this.renderer.shadowMap.enabled = true;
    this.renderer.shadowMap.type = THREE.PCFSoftShadowMap;
    container.appendChild(this.renderer.domElement);

    // Create scene and camera
    const { scene, camera } = createScene(width, height);
    this.scene = scene;
    this.camera = camera;

    // IMPORTANT: camera.up must be set BEFORE creating OrbitControls
    this.camera.up.set(0, 0, 1);

    // Add orbit controls
    this.controls = new OrbitControls(this.camera, this.renderer.domElement);
    this.controls.enableDamping = true;
    this.controls.dampingFactor = 0.05;
    this.controls.target.set(0, 0, 0);
    this.controls.update();

    // Build robot from topology
    this.robot = null;
    if (topology) {
      this.robot = buildRobot(topology, positions);
      this.scene.add(this.robot);

      // Auto-frame the robot
      frameRobot(this.camera, this.controls, this.robot);
    }

    // Store initial camera position for reset
    this.initialCameraPosition = this.camera.position.clone();
    this.initialControlsTarget = this.controls.target.clone();

    // Reset view button
    resetViewBtn.addEventListener("click", () => {
      this.camera.position.copy(this.initialCameraPosition);
      this.controls.target.copy(this.initialControlsTarget);
      this.controls.update();
    });

    // Animation loop
    this.animationId = null;
    this.animate();

    // Handle position updates from server
    this.handleEvent("positions_updated", ({ positions }) => {
      if (this.robot && positions) {
        this.robot.setJointValues(positions);
      }
    });

    // Handle window resize
    this.resizeObserver = new ResizeObserver((entries) => {
      for (const entry of entries) {
        const { width: newWidth } = entry.contentRect;
        if (newWidth > 0) {
          const newHeight = 400;
          this.camera.aspect = newWidth / newHeight;
          this.camera.updateProjectionMatrix();
          this.renderer.setSize(newWidth, newHeight);
        }
      }
    });
    this.resizeObserver.observe(container);
  },

  animate() {
    this.animationId = requestAnimationFrame(() => this.animate());

    // Skip rendering while hidden (e.g. behind the Images tab); the scene is
    // kept so switching back is instant.
    if (this.el.offsetParent === null) return;

    this.controls.update();
    this.renderer.render(this.scene, this.camera);
  },

  showError(message) {
    this.el.innerHTML = `
      <div class="bb-vis bb-vis-error">
        <span class="bb-vis-error-message">${message}</span>
      </div>
    `;
  },

  cleanup() {
    if (this.animationId) {
      cancelAnimationFrame(this.animationId);
    }
    if (this.resizeObserver) {
      this.resizeObserver.disconnect();
    }
    if (this.renderer) {
      this.renderer.dispose();
    }
    if (this.controls) {
      this.controls.dispose();
    }
  },
};
