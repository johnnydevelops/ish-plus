//
//  AboutViewController.m
//  iSH
//
//  Created by Theodore Dubois on 9/23/18.
//

#import "AboutViewController.h"
#import "iSHSwift.h"
#import "AppDelegate.h"
#import "AppGroup.h"
#import "UserPreferences.h"
#import "UIApplication+OpenURL.h"
#import "NSObject+SaneKVO.h"

@interface AboutViewController ()
@property (weak, nonatomic) IBOutlet UITableViewCell *capsLockMappingCell;
@property (weak, nonatomic) IBOutlet UITableViewCell *themeCell;
@property (weak, nonatomic) IBOutlet UISwitch *disableDimmingSwitch;
@property (weak, nonatomic) IBOutlet UISwitch *keepAliveSwitch;
@property (weak, nonatomic) IBOutlet UITableViewCell *jitSetupCell;
@property (weak, nonatomic) IBOutlet UITableViewCell *distrosCell;
@property (weak, nonatomic) IBOutlet UITableViewCell *vmSettingsCell;

@property (weak, nonatomic) IBOutlet UITableViewCell *openGithub;
@property (weak, nonatomic) IBOutlet UITableViewCell *openFediverse;


@property (weak, nonatomic) IBOutlet UILabel *versionLabel;

@property (weak, nonatomic) IBOutlet NSLayoutConstraint *saddamHussein;

@end

@implementation AboutViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    [self _updateUI];
    if (self.recoveryMode) {
        self.includeDebugPanel = YES;
        self.navigationItem.title = @"Recovery Mode";
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Exit"
                                                                                  style:UIBarButtonItemStyleDone
                                                                                 target:self
                                                                                 action:@selector(exitRecovery:)];
        self.navigationItem.leftBarButtonItem = nil;
    }
    _versionLabel.text = [NSString stringWithFormat:@"iSH+ %@ (Build %@)",
                          [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"],
                          [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"]];

    [UserPreferences.shared observe:@[@"capsLockMapping", @"fontSize"]
                            options:0 owner:self usingBlock:^(typeof(self) self) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _updateUI];
        });
    }];
}

// Shows whether iSH+ can enable JIT by itself.
- (void)updateJITSetupCell {
    UIListContentConfiguration *content = [UIListContentConfiguration valueCellConfiguration];
    content.text = @"JIT Setup";
    content.secondaryText = ISHOnboarding.hasPairing ? @"Paired" : @"Not Set Up";
    self.jitSetupCell.contentConfiguration = content;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self updateJITSetupCell];
    [self _updateUI];
}

- (void)updateViewConstraints {
    self.saddamHussein.constant = UIEdgeInsetsInsetRect(self.tableView.frame, self.tableView.adjustedContentInset).size.height;
    [super updateViewConstraints];
}

- (IBAction)dismiss:(id)sender {
    [self dismissViewControllerAnimated:self completion:nil];
}

- (void)exitRecovery:(id)sender {
    [NSUserDefaults.standardUserDefaults setBool:NO forKey:@"recovery"];
    exit(0);
}

- (void)_updateUI:(NSNotification *)notification {
    [self _updateUI];
}

- (void)_updateUI {
    NSAssert(NSThread.isMainThread, @"This method needs to be called on the main thread");
    self.disableDimmingSwitch.on = UserPreferences.shared.shouldDisableDimming;
    self.keepAliveSwitch.on = UserPreferences.shared.keepAliveInBackground;
    [self.tableView reloadData];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    if (cell == self.vmSettingsCell) {
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        [self.navigationController pushViewController:[ISHVMSettingsViewController new] animated:YES];
    } else if (cell == self.distrosCell) {
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        [self.navigationController pushViewController:[ISHDistrosViewController new] animated:YES];
    } else if (cell == self.jitSetupCell) {
        __weak typeof(self) weakSelf = self;
        ISHOnboardingViewController *onboarding = [[ISHOnboardingViewController alloc] initWithCompletion:^{
            [weakSelf updateJITSetupCell];
        }];
        onboarding.fromSettings = YES;
        [self presentViewController:onboarding animated:YES completion:nil];
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
    } else if (cell == self.openGithub) {
        [UIApplication openURL:@"https://github.com/johnnydevelops/ish-plus"];
    } else if (cell == self.openFediverse) {
        // "Based on iSH"
        [UIApplication openURL:@"https://github.com/ish-app/ish"];
    }
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
}

- (IBAction)disableDimmingChanged:(id)sender {
    UserPreferences.shared.shouldDisableDimming = self.disableDimmingSwitch.on;
}

- (IBAction)keepAliveChanged:(id)sender {
    UserPreferences.shared.keepAliveInBackground = self.keepAliveSwitch.on;
}

- (IBAction)textBoxSubmit:(id)sender {
    [sender resignFirstResponder];
}

@end
