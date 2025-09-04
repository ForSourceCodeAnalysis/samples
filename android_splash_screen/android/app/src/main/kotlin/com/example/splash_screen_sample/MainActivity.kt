/*
 * Copyright (C) 2021 The Android Open Source Project
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
  * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package com.example.splash_screen_sample

import android.animation.AnimatorSet
import android.animation.ObjectAnimator
import android.animation.ValueAnimator
import android.os.Bundle
import android.transition.AutoTransition
import android.transition.Transition
import android.transition.TransitionManager
import android.view.animation.AccelerateDecelerateInterpolator
import android.view.View
import android.widget.FrameLayout
import androidx.constraintlayout.widget.ConstraintLayout
import androidx.constraintlayout.widget.ConstraintSet
import androidx.core.animation.doOnEnd
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import androidx.core.splashscreen.SplashScreenViewProvider
import androidx.core.view.postDelayed
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.interpolator.view.animation.FastOutLinearInInterpolator
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {

  var flutterUIReady : Boolean = false
  var initialAnimationFinished : Boolean = false

  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)

    // This activity will be handling the splash screen transition.
    // 使用 AndroidX 的 SplashScreen API 安装系统级启动屏。
    val splashScreen = installSplashScreen()

    // The splash screen goes edge to edge, so for a smooth transition to our app, also
    // want to draw edge to edge.
    //全屏适配 通过 setDecorFitsSystemWindows(false) 实现内容延伸到系统栏（状态栏/导航栏），符合 Material Design 3 的沉浸式设计规范。
    WindowCompat.setDecorFitsSystemWindows(window, false)



    val insetsController = WindowCompat.getInsetsController(window, window.decorView)
    insetsController?.isAppearanceLightNavigationBars = true
    insetsController?.isAppearanceLightStatusBars = true

    // The content view needs to be set before calling setOnExitAnimationListener
    // to ensure that the SplashScreenView is attached to the right view root.
    val rootLayout = findViewById(android.R.id.content) as FrameLayout
    View.inflate(this, R.layout.main_activity_2, rootLayout)

    ViewCompat.setOnApplyWindowInsetsListener(findViewById(R.id.container)) { view, windowInsets ->
      val insets = windowInsets.getInsets(WindowInsetsCompat.Type.systemBars())
      view.setPadding(insets.left, insets.top, insets.right, insets.bottom)
      windowInsets.inset(insets)
    }

    // Setting an OnExitAnimationListener on the splash screen indicates
    // to the system that the application will handle the exit animation.
    // The listener will be called once the app is ready.
    splashScreen.setOnExitAnimationListener { splashScreenViewProvider ->
      onSplashScreenExit(splashScreenViewProvider)
    }
  }


// 状态监听：覆盖 FlutterActivity 的回调方法，在 Flutter UI 显示/隐藏时更新状态变量 flutterUIReady。
// 同步逻辑：只有当 Flutter UI 和初始动画都完成后，才触发 splash screen 的隐藏动画，确保过渡流畅。
  override fun onFlutterUiDisplayed(){
    flutterUIReady = true

    if (initialAnimationFinished) {
      hideSplashScreenAnimation()
    }
  }

  override fun onFlutterUiNoLongerDisplayed(){
    flutterUIReady = false
  }

  /**
   * Hides the splash screen only when the entire animation has finished and the Flutter UI is ready to display.
   */
  private fun hideSplashScreenAnimation(){
    val splashView = findViewById(R.id.container) as ConstraintLayout
    splashView
      .animate()
      .alpha(0.0f)
      .setDuration(SPLASHSCREEN_FINAL_ANIMATION_ALPHA_ANIMATION_DURATION)
  }

  /**
   * Handles the transition from the splash screen to the application.
   * 自定义退出动画
   *
   * 多动画组合：通过 AnimatorSet 和 ObjectAnimator 实现 Alpha 淡出和图标下移的组合动画。
   * ConstraintLayout 过渡：使用 ConstraintSet 定义动画起始和结束的布局约束，通过 TransitionManager 实现布局变化的平滑过渡。
   * 动画同步：通过 doOnEnd 确保动画结束后移除启动屏视图，避免残留。
   * 等待机制：waitForAnimatedIconToFinish 方法确保图标动画完成后才启动主动画，防止视觉冲突。
   */
  private fun onSplashScreenExit(splashScreenViewProvider: SplashScreenViewProvider) {
    val accelerateInterpolator = FastOutLinearInInterpolator()
    val splashScreenView = splashScreenViewProvider.view
    val iconView = splashScreenViewProvider.iconView

    // Change the alpha of the main view.
    // 1.创建Alpha 动画
    val alpha = ValueAnimator.ofInt(255, 0)
    alpha.duration = SPLASHSCREEN_ALPHA_ANIMATION_DURATION
    alpha.interpolator = accelerateInterpolator

    // 创建图标下移动画
    // And translate the icon down.
    val translationY = ObjectAnimator.ofFloat(
      iconView,
      View.TRANSLATION_Y,
      iconView.translationY,
      splashScreenView.height.toFloat()
    )
    translationY.duration = SPLASHSCREEN_TY_ANIMATION_DURATION
    translationY.interpolator = accelerateInterpolator

    // 组合动画
    // And play all of the animation together.
    val animatorSet = AnimatorSet()
    animatorSet.playTogether(alpha)


    //使用ConstraintLayout过渡动画
    // Apply layout constraints of starting frame of animation to
    // FrameLayout's container for the TransitionManager to know
    // where to start the transition.
    val root = findViewById<ConstraintLayout>(R.id.container)
    val set1 = ConstraintSet().apply {
      clone(this@MainActivity, R.layout.main_activity)
    }
    set1.applyTo(root)

    // Retrieve layout constraints of final frame of animation
    // for TransitionManager to know where to end the transition.
    val set2 = ConstraintSet().apply {
      clone(this@MainActivity, R.layout.main_activity_2)
    }

    var transitionStarted = false
    val autoTransition = AutoTransition().apply {
      interpolator = AccelerateDecelerateInterpolator()
    }
    autoTransition.addListener(object: Transition.TransitionListener {
      override fun onTransitionEnd(transition: Transition) {
        initialAnimationFinished = true

        if (flutterUIReady) {
          hideSplashScreenAnimation()
        }
    }
      override fun onTransitionCancel(transition: Transition){}
      override fun onTransitionPause(transition: Transition) {}
      override fun onTransitionResume(transition: Transition) {}
      override fun onTransitionStart(transition: Transition) {}
    })

    val alphaUpdateListener: (ValueAnimator) -> Unit = { valueAnimator ->
      if (!transitionStarted && valueAnimator.animatedFraction > 0.5) {
        transitionStarted = true

        TransitionManager.beginDelayedTransition(root, autoTransition)
        iconView.visibility = View.GONE

        // Apply constraints of final frame of animation to
        // FrameLayout's container once the transition is in progress.
        set2.applyTo(root)
      }
      splashScreenView.background.alpha = valueAnimator.animatedValue as Int
    }
    alpha.addUpdateListener(alphaUpdateListener)

    //动画完成时移除启动屏
    // Once the application is finished, remove the splash screen from our view
    // hierarchy.
    animatorSet.doOnEnd {
      splashScreenViewProvider.remove()
    }
    // 等待图标动画完成后启动主动画
    waitForAnimatedIconToFinish(splashScreenViewProvider, splashScreenView) {
      animatorSet.start()
    }
  }

  /**
   * Wait until the AVD animation is finished before starting the splash screen dismiss animation.
   */
  private fun SplashScreenViewProvider.remainingAnimationDuration() = iconAnimationStartMillis +
    iconAnimationDurationMillis - System.currentTimeMillis()

  private fun waitForAnimatedIconToFinish(
    splashScreenViewProvider: SplashScreenViewProvider,
    view: View,
    onAnimationFinished: () -> Unit
  ) {
    // If wanting to wait for our Animated Vector Drawable to finish animating, can compute
    // the remaining time to delay the start of the exit animation.
    val delayMillis: Long =
      if (WAIT_FOR_AVD_TO_FINISH) splashScreenViewProvider.remainingAnimationDuration() else 0
    view.postDelayed(delayMillis, onAnimationFinished)
  }

  // 动画时长：定义了 Alpha 动画和位移动画的持续时间，符合 Material Design 的动画规范（通常 200-500ms）。
  // 开关配置：WAIT_FOR_AVD_TO_FINISH 控制是否等待矢量动画完成，方便快速调试。
  private companion object {
    const val SPLASHSCREEN_ALPHA_ANIMATION_DURATION = 500L
    const val SPLASHSCREEN_TY_ANIMATION_DURATION = 500L
    const val SPLASHSCREEN_FINAL_ANIMATION_ALPHA_ANIMATION_DURATION = 250L
    const val WAIT_FOR_AVD_TO_FINISH = false
  }
}
