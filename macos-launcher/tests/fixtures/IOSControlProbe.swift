// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Keye3Tuido
// Test-only UIKit/WebKit screens. Not included in the distributed app.
import UIKit
import WebKit

class TouchArea: UIView {
    var began: TimeInterval = 0
    var points: [[Double]] = []
    var result: UILabel!
    func capture(_ touches: Set<UITouch>) {
        guard let touch = touches.first else { return }
        let point = touch.location(in: self)
        points.append([Double(point.x / bounds.width), Double(point.y / bounds.height), touch.timestamp - began])
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        began = touches.first!.timestamp; points = []; capture(touches)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { capture(touches) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        capture(touches)
        result.text = String(data: try! JSONSerialization.data(withJSONObject: points), encoding: .utf8)
    }
}

class Rows: UITableViewController {
    override func viewDidLoad() { super.viewDidLoad(); title = "Rows" }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 60 }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(); cell.textLabel!.text = "Row \(indexPath.row)"; return cell
    }
}

class Probe: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad(); title = "Root"; view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Compose", style: .plain, target: self, action: #selector(compose))
        let stack = UIStackView(); stack.axis = .vertical; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(stack)
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 30), stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 40), stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -40)])
        for (name, action) in [("standard", #selector(standard)), ("custom", #selector(custom)), ("web", #selector(web)), ("touch", #selector(touch)), ("scroll", #selector(scroll))] {
            let button = UIButton(type: .system); button.setTitle(name, for: .normal); button.accessibilityIdentifier = name
            button.addTarget(self, action: action, for: .touchUpInside); stack.addArrangedSubview(button)
        }
    }
    @objc func scroll() { navigationController!.pushViewController(Rows(), animated: false) }
    @objc func compose() { title = "WRONG COMPOSE" }
    @objc func standard() {
        let page = UIViewController(); page.title = "Detail"; page.view.backgroundColor = .systemGreen
        navigationController!.pushViewController(page, animated: false)
    }
    func page() -> UIViewController {
        let page = UIViewController(); page.modalPresentationStyle = .fullScreen; page.view.backgroundColor = .systemBackground
        present(page, animated: false); return page
    }
    @objc func dismissPage() { dismiss(animated: false) }
    @objc func custom() {
        let page = page(); let button = UIButton(type: .system); button.setTitle("返回", for: .normal)
        button.accessibilityIdentifier = "custom-back"; button.frame = CGRect(x: 40, y: 140, width: 240, height: 80)
        button.addTarget(self, action: #selector(dismissPage), for: .touchUpInside); page.view.addSubview(button)
    }
    @objc func web() {
        let page = page(); let web = WKWebView(frame: page.view.bounds); web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        page.view.addSubview(web)
        web.loadHTMLString("""
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <body style="padding:80px 20px;font:24px sans-serif"><h1 id="page">Second page</h1>
        <button style="font-size:24px;padding:20px" onclick="document.querySelector('h1').textContent='First page';this.remove()">Back</button></body>
        """, baseURL: nil)
    }
    @objc func touch() {
        let page = page(); let result = UILabel(); result.text = "Waiting"; result.accessibilityIdentifier = "touch-result"
        result.frame = CGRect(x: 20, y: 90, width: page.view.bounds.width - 40, height: 50); page.view.addSubview(result)
        let area = TouchArea(); area.result = result; area.backgroundColor = .systemTeal; area.accessibilityIdentifier = "touch-area"
        area.isAccessibilityElement = true; area.frame = CGRect(x: 20, y: 160, width: page.view.bounds.width - 40, height: page.view.bounds.height - 200)
        area.autoresizingMask = [.flexibleWidth, .flexibleHeight]; page.view.addSubview(area)
    }
}
class Delegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ app: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        window = UIWindow(frame: UIScreen.main.bounds); window!.rootViewController = UINavigationController(rootViewController: Probe()); window!.makeKeyAndVisible(); return true
    }
}
UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(Delegate.self))
